/*
 * Copyright (C) 2017 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "config.h"
#import "CDMInstanceFairPlayStreamingAVFObjC.h"

#if ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)

#import "CDMFairPlayStreaming.h"
#import "CDMKeySystemConfiguration.h"
#import "CDMMediaCapability.h"
#import "InitDataRegistry.h"
#import "NotImplemented.h"
#import "SharedBuffer.h"
#import "TextDecoder.h"
#import <AVFoundation/AVContentKeySession.h>
#import <objc/runtime.h>
#import <pal/spi/mac/AVFoundationSPI.h>
#import <wtf/Algorithms.h>
#import <wtf/FileSystem.h>
#import <wtf/JSONValues.h>
#import <wtf/text/Base64.h>
#import <wtf/text/StringHash.h>

#import <pal/cocoa/AVFoundationSoftLink.h>

static const NSString *PlaybackSessionIdKey = @"PlaybackSessionID";

@interface WebCoreFPSContentKeySessionDelegate : NSObject<AVContentKeySessionDelegate> {
    WebCore::CDMInstanceSessionFairPlayStreamingAVFObjC* _parent;
}
@end

@implementation WebCoreFPSContentKeySessionDelegate
- (id)initWithParent:(WebCore::CDMInstanceSessionFairPlayStreamingAVFObjC *)parent
{
    if (!(self = [super init]))
        return nil;

    _parent = parent;
    return self;
}

- (void)invalidate
{
    _parent = nil;
}

- (void)contentKeySession:(AVContentKeySession *)session didProvideContentKeyRequest:(AVContentKeyRequest *)keyRequest
{
    UNUSED_PARAM(session);
    if (_parent)
        _parent->didProvideRequest(keyRequest);
}

- (void)contentKeySession:(AVContentKeySession *)session didProvideRenewingContentKeyRequest:(AVContentKeyRequest *)keyRequest
{
    UNUSED_PARAM(session);
    if (_parent)
        _parent->didProvideRenewingRequest(keyRequest);
}

#if PLATFORM(IOS_FAMILY)
- (void)contentKeySession:(AVContentKeySession *)session didProvidePersistableContentKeyRequest:(AVPersistableContentKeyRequest *)keyRequest
{
    UNUSED_PARAM(session);
    if (_parent)
        _parent->didProvidePersistableRequest(keyRequest);
}

- (void)contentKeySession:(AVContentKeySession *)session didUpdatePersistableContentKey:(NSData *)persistableContentKey forContentKeyIdentifier:(id)keyIdentifier
{
    UNUSED_PARAM(session);
    UNUSED_PARAM(persistableContentKey);
    UNUSED_PARAM(keyIdentifier);
    notImplemented();
}
#endif

- (void)contentKeySession:(AVContentKeySession *)session didProvideContentKeyRequests:(NSArray<AVContentKeyRequest *> *)keyRequests forInitializationData:(nullable NSData *)initializationData
{
    UNUSED_PARAM(session);
    UNUSED_PARAM(initializationData);
    if (!_parent)
        return;

    Vector<RetainPtr<AVContentKeyRequest>> requests;
    requests.reserveInitialCapacity(keyRequests.count);
    [keyRequests enumerateObjectsUsingBlock:[&](AVContentKeyRequest* request, NSUInteger, BOOL*) {
        requests.uncheckedAppend(request);
    }];
    _parent->didProvideRequests(WTFMove(requests));
}

- (void)contentKeySession:(AVContentKeySession *)session contentKeyRequest:(AVContentKeyRequest *)keyRequest didFailWithError:(NSError *)err
{
    UNUSED_PARAM(session);
    if (_parent)
        _parent->didFailToProvideRequest(keyRequest, err);
}

- (void)contentKeySession:(AVContentKeySession *)session contentKeyRequestDidSucceed:(AVContentKeyRequest *)keyRequest
{
    UNUSED_PARAM(session);
    if (_parent)
        _parent->requestDidSucceed(keyRequest);
}

- (BOOL)contentKeySession:(AVContentKeySession *)session shouldRetryContentKeyRequest:(AVContentKeyRequest *)keyRequest reason:(AVContentKeyRequestRetryReason)retryReason
{
    UNUSED_PARAM(session);
    return _parent ? _parent->shouldRetryRequestForReason(keyRequest, retryReason) : false;
}

- (void)contentKeySessionContentProtectionSessionIdentifierDidChange:(AVContentKeySession *)session
{
    UNUSED_PARAM(session);
    if (_parent)
        _parent->sessionIdentifierChanged(session.contentProtectionSessionIdentifier);
}

@end

namespace WebCore {

class CDMInstanceSessionFairPlayStreamingAVFObjC::UpdateResponseCollector {
    WTF_MAKE_FAST_ALLOCATED;
public:
    using KeyType = RetainPtr<AVContentKeyRequest>;
    using ValueType = RetainPtr<NSData>;
    using ResponseMap = HashMap<KeyType, ValueType>;
    using UpdateCallback = WTF::Function<void(Optional<ResponseMap>&&)>;
    UpdateResponseCollector(size_t numberOfExpectedResponses, UpdateCallback&& callback)
        : m_numberOfExpectedResponses(numberOfExpectedResponses)
        , m_callback(WTFMove(callback))
    {
    }

    void addSuccessfulResponse(AVContentKeyRequest* request, NSData* data)
    {
        m_responses.set(request, data);
        if (!--m_numberOfExpectedResponses)
            m_callback(WTFMove(m_responses));
    }
    void addErrorResponse(AVContentKeyRequest* request, NSError* error)
    {
        UNUSED_PARAM(error);
        m_responses.set(request, nullptr);
        if (!--m_numberOfExpectedResponses)
            m_callback(WTFMove(m_responses));
    }
    void fail()
    {
        m_callback(WTF::nullopt);
    }

private:
    size_t m_numberOfExpectedResponses;
    UpdateCallback m_callback;
    ResponseMap m_responses;
};

static RefPtr<JSON::Value> parseJSONValue(const SharedBuffer& buffer)
{
    // Fail on large buffers whose size doesn't fit into a 32-bit unsigned integer.
    size_t size = buffer.size();
    if (size > std::numeric_limits<unsigned>::max())
        return nullptr;

    // Parse the buffer contents as JSON, returning the root object (if any).
    String json { buffer.data(), static_cast<unsigned>(size) };
    RefPtr<JSON::Value> value;
    if (!JSON::Value::parseJSON(json, value))
        return nullptr;

    return value;
}

bool CDMInstanceFairPlayStreamingAVFObjC::supportsPersistableState()
{
    return [PAL::getAVContentKeySessionClass() respondsToSelector:@selector(pendingExpiredSessionReportsWithAppIdentifier:storageDirectoryAtURL:)];
}

bool CDMInstanceFairPlayStreamingAVFObjC::supportsPersistentKeys()
{
#if PLATFORM(IOS_FAMILY)
    return PAL::getAVPersistableContentKeyRequestClass();
#else
    return false;
#endif
}

bool CDMInstanceFairPlayStreamingAVFObjC::supportsMediaCapability(const CDMMediaCapability& capability)
{
    if (![PAL::getAVURLAssetClass() isPlayableExtendedMIMEType:capability.contentType])
        return false;

    // FairPlay only supports 'cbcs' encryption:
    if (capability.encryptionScheme && capability.encryptionScheme.value() != CDMEncryptionScheme::cbcs)
        return false;

    return true;
}

CDMInstance::SuccessValue CDMInstanceFairPlayStreamingAVFObjC::initializeWithConfiguration(const CDMKeySystemConfiguration& configuration)
{
    // FIXME: verify that FairPlayStreaming does not (and cannot) expose a distinctive identifier to the client
    if (configuration.distinctiveIdentifier == CDMRequirement::Required)
        return Failed;

    if (configuration.persistentState != CDMRequirement::Required && (configuration.sessionTypes.contains(CDMSessionType::PersistentUsageRecord) || configuration.sessionTypes.contains(CDMSessionType::PersistentLicense)))
        return Failed;

    if (configuration.persistentState == CDMRequirement::Required && !m_storageURL)
        return Failed;

    if (configuration.sessionTypes.contains(CDMSessionType::PersistentLicense) && !supportsPersistentKeys())
        return Failed;

    if (!PAL::canLoad_AVFoundation_AVContentKeySystemFairPlayStreaming())
        return Failed;

    return Succeeded;
}

CDMInstance::SuccessValue CDMInstanceFairPlayStreamingAVFObjC::setDistinctiveIdentifiersAllowed(bool)
{
    // FIXME: verify that FairPlayStreaming does not (and cannot) expose a distinctive identifier to the client
    return Succeeded;
}

CDMInstance::SuccessValue CDMInstanceFairPlayStreamingAVFObjC::setPersistentStateAllowed(bool persistentStateAllowed)
{
    m_persistentStateAllowed = persistentStateAllowed;
    return Succeeded;
}

CDMInstance::SuccessValue CDMInstanceFairPlayStreamingAVFObjC::setServerCertificate(Ref<SharedBuffer>&& serverCertificate)
{
    m_serverCertificate = WTFMove(serverCertificate);
    return Succeeded;
}

CDMInstance::SuccessValue CDMInstanceFairPlayStreamingAVFObjC::setStorageDirectory(const String& storageDirectory)
{
    if (storageDirectory.isEmpty()) {
        m_storageURL = nil;
        return Succeeded;
    }

    auto storagePath = FileSystem::pathByAppendingComponent(storageDirectory, "SecureStop.plist");

    if (!FileSystem::fileExists(storageDirectory)) {
        if (!FileSystem::makeAllDirectories(storageDirectory))
            return Failed;
    } else if (!FileSystem::fileIsDirectory(storageDirectory, FileSystem::ShouldFollowSymbolicLinks::Yes)) {
        auto tempDirectory = FileSystem::createTemporaryDirectory(@"MediaKeys");
        if (!tempDirectory)
            return Failed;

        auto tempStoragePath = FileSystem::pathByAppendingComponent(tempDirectory, FileSystem::pathGetFileName(storagePath));
        if (!FileSystem::moveFile(storageDirectory, tempStoragePath))
            return Failed;

        if (!FileSystem::moveFile(tempDirectory, storageDirectory))
            return Failed;
    }

    m_storageURL = adoptNS([[NSURL alloc] initFileURLWithPath:storagePath isDirectory:NO]);
    return Succeeded;
}

RefPtr<CDMInstanceSession> CDMInstanceFairPlayStreamingAVFObjC::createSession()
{
    auto session = adoptRef(*new CDMInstanceSessionFairPlayStreamingAVFObjC(*this));
    m_sessions.append(makeWeakPtr(session.get()));
    return session;
}

const String& CDMInstanceFairPlayStreamingAVFObjC::keySystem() const
{
    static NeverDestroyed<String> keySystem { "com.apple.fps"_s };
    return keySystem;
}

void CDMInstanceFairPlayStreamingAVFObjC::outputObscuredDueToInsufficientExternalProtectionChanged(bool obscured)
{
    for (auto& sessionInterface : m_sessions) {
        if (sessionInterface)
            sessionInterface->outputObscuredDueToInsufficientExternalProtectionChanged(obscured);
    }
}

CDMInstanceSessionFairPlayStreamingAVFObjC* CDMInstanceFairPlayStreamingAVFObjC::sessionForKeyIDs(const Keys& keyIDs) const
{
    for (auto& sessionInterface : m_sessions) {
        if (!sessionInterface)
            continue;

        auto sessionKeys = sessionInterface->keyIDs();
        if (anyOf(sessionKeys, [&](auto& sessionKey) {
            return keyIDs.contains(sessionKey);
        }))
            return sessionInterface.get();
    }
    return nullptr;
}

CDMInstanceSessionFairPlayStreamingAVFObjC::CDMInstanceSessionFairPlayStreamingAVFObjC(Ref<CDMInstanceFairPlayStreamingAVFObjC>&& instance)
    : m_instance(WTFMove(instance))
    , m_delegate([[WebCoreFPSContentKeySessionDelegate alloc] initWithParent:this])
{
}

CDMInstanceSessionFairPlayStreamingAVFObjC::~CDMInstanceSessionFairPlayStreamingAVFObjC()
{
    [m_delegate invalidate];
}

using Keys = CDMInstanceSessionFairPlayStreamingAVFObjC::Keys;
static Keys keyIDsForRequest(AVContentKeyRequest* request)
{
    if ([request.identifier isKindOfClass:[NSString class]])
        return Keys::from(SharedBuffer::create([(NSString *)request.identifier dataUsingEncoding:NSUTF8StringEncoding]));
    if ([request.identifier isKindOfClass:[NSData class]])
        return Keys::from(SharedBuffer::create((NSData *)request.identifier));
    if (request.initializationData) {
        if (auto sinfKeyIDs = CDMPrivateFairPlayStreaming::extractKeyIDsSinf(SharedBuffer::create(request.initializationData)))
            return WTFMove(sinfKeyIDs.value());
    }
    return { };
}

using Request = CDMInstanceSessionFairPlayStreamingAVFObjC::Request;
static Keys keyIDsForRequest(const Request& requests)
{
    Keys keyIDs;
    for (auto& request : requests)
        keyIDs.appendVector(keyIDsForRequest(request.get()));
    return keyIDs;
}

Keys CDMInstanceSessionFairPlayStreamingAVFObjC::keyIDs()
{
    // FIXME(rdar://problem/35597141): use the future AVContentKeyRequest keyID property, rather than parsing it out of the init
    // data, to get the keyID.
    Keys keyIDs;
    for (auto& request : m_requests) {
        for (auto& key : keyIDsForRequest(request))
            keyIDs.append(WTFMove(key));
    }

    return keyIDs;
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::requestLicense(LicenseType licenseType, const AtomString& initDataType, Ref<SharedBuffer>&& initData, LicenseCallback&& callback)
{
    if (!isLicenseTypeSupported(licenseType)) {
        callback(SharedBuffer::create(), emptyString(), false, Failed);
        return;
    }

    if (!m_instance->serverCertificate()) {
        callback(SharedBuffer::create(), emptyString(), false, Failed);
        return;
    }

    if (!ensureSession()) {
        callback(SharedBuffer::create(), emptyString(), false, Failed);
        return;
    }

    RetainPtr<NSString> identifier;
    RetainPtr<NSData> initializationData;

    if (initDataType == CDMPrivateFairPlayStreaming::sinfName())
        initializationData = initData->createNSData();
    else if (initDataType == CDMPrivateFairPlayStreaming::skdName())
        identifier = adoptNS([[NSString alloc] initWithData:initData->createNSData().get() encoding:NSUTF8StringEncoding]);
#if HAVE(FAIRPLAYSTREAMING_CENC_INITDATA)
    else if (initDataType == InitDataRegistry::cencName()) {
        String psshString = base64Encode(initData->data(), initData->size());
        initializationData = [NSJSONSerialization dataWithJSONObject:@{ @"pssh": (NSString*)psshString } options:NSJSONWritingPrettyPrinted error:nil];
    }
#endif
    else {
        callback(SharedBuffer::create(), emptyString(), false, Failed);
        return;
    }

    m_requestLicenseCallback = WTFMove(callback);
    [m_session processContentKeyRequestWithIdentifier:identifier.get() initializationData:initializationData.get() options:nil];
}

static bool isEqual(const SharedBuffer& data, const String& value)
{
    auto arrayBuffer = data.tryCreateArrayBuffer();
    if (!arrayBuffer)
        return false;

    auto exceptionOrDecoder = TextDecoder::create("utf8"_s, TextDecoder::Options());
    if (exceptionOrDecoder.hasException())
        return false;

    Ref<TextDecoder> decoder = exceptionOrDecoder.releaseReturnValue();
    auto stringOrException = decoder->decode(BufferSource::VariantType(WTFMove(arrayBuffer)), TextDecoder::DecodeOptions());
    if (stringOrException.hasException())
        return false;

    return stringOrException.returnValue() == value;
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::updateLicense(const String&, LicenseType, const SharedBuffer& responseData, LicenseUpdateCallback&& callback)
{
    if (!m_expiredSessions.isEmpty() && isEqual(responseData, "acknowledged"_s)) {
        auto expiredSessions = adoptNS([[NSMutableArray alloc] init]);
        for (auto& session : m_expiredSessions)
            [expiredSessions addObject:session.get()];

        auto* certificate = m_instance->serverCertificate();
        auto* storageURL = m_instance->storageURL();

        if (!certificate || !storageURL) {
            callback(false, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
            return;
        }

        RetainPtr<NSData> appIdentifier = certificate->createNSData();
        [PAL::getAVContentKeySessionClass() removePendingExpiredSessionReports:expiredSessions.get() withAppIdentifier:appIdentifier.get() storageDirectoryAtURL:storageURL];
        callback(false, { }, WTF::nullopt, WTF::nullopt, Succeeded);
        return;
    }

    if (!m_requests.isEmpty() && isEqual(responseData, "renew"_s)) {
        auto request = lastKeyRequest();
        if (!request) {
            callback(false, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
            return;
        }
        [m_session renewExpiringResponseDataForContentKeyRequest:request];
        m_updateLicenseCallback = WTFMove(callback);
        return;
    }

    if (m_currentRequest.isEmpty()) {
        callback(false, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
        return;
    }
    Keys keyIDs = keyIDsForRequest(m_currentRequest);
    if (keyIDs.isEmpty()) {
        callback(false, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
        return;
    }

    if (m_currentRequest.size() > 1) {
        if (m_updateResponseCollector) {
            m_updateResponseCollector->fail();
            m_updateResponseCollector = nullptr;
        }

        m_updateResponseCollector = WTF::makeUnique<UpdateResponseCollector>(m_currentRequest.size(), [weakThis = makeWeakPtr(*this), this] (Optional<UpdateResponseCollector::ResponseMap>&& responses) {
            if (!weakThis)
                return;

            if (!m_updateLicenseCallback)
                return;

            if (!responses || responses.value().isEmpty()) {
                m_updateLicenseCallback(true, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
                return;
            }

            m_updateLicenseCallback(false, keyStatuses(), WTF::nullopt, WTF::nullopt, Succeeded);
            m_updateResponseCollector = nullptr;
            m_currentRequest.clear();
            nextRequest();
        });

        auto root = parseJSONValue(responseData);
        RefPtr<JSON::Array> array;
        if (!root || !root->asArray(array)) {
            callback(false, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
            return;
        }

        auto parseResponse = [&](RefPtr<JSON::Value>& value) -> bool {
            RefPtr<JSON::Object> object;
            if (!value->asObject(object))
                return false;

            String keyIDString;
            if (!object->getString("keyID", keyIDString))
                return false;

            Vector<uint8_t> keyIDVector;
            if (!base64Decode(keyIDString, keyIDVector))
                return false;

            auto keyID = SharedBuffer::create(WTFMove(keyIDVector));
            auto foundIndex = m_currentRequest.findMatching([&] (auto& request) {
                auto keyIDs = keyIDsForRequest(request.get());
                return keyIDs.contains(keyID);
            });
            if (foundIndex == notFound)
                return false;

            auto& request = m_currentRequest[foundIndex];

            auto payloadFindResults = object->find("payload");
            auto errorFindResults = object->find("error");
            bool hasPayload = payloadFindResults != object->end();
            bool hasError = errorFindResults != object->end();

            // Either "payload" or "error" are present, but not both
            if (hasPayload == hasError)
                return false;

            if (hasError) {
                NSInteger errorCode;
                if (!errorFindResults->value->asInteger(errorCode))
                    return false;
                auto error = adoptNS([[NSError alloc] initWithDomain:@"org.webkit.eme" code:errorCode userInfo:nil]);
                [request processContentKeyResponseError:error.get()];
            } else if (hasPayload) {
                String payloadString;
                if (!payloadFindResults->value->asString(payloadString))
                    return false;
                Vector<uint8_t> payloadVector;
                if (!base64Decode(payloadString, payloadVector))
                    return false;
                auto payloadData = SharedBuffer::create(WTFMove(payloadVector));
                [request processContentKeyResponse:[PAL::getAVContentKeyResponseClass() contentKeyResponseWithFairPlayStreamingKeyResponseData:payloadData->createNSData().get()]];
            }
            return true;
        };
        for (auto value : *array) {
            if (!parseResponse(value)) {
                callback(false, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
                return;
            }
        }
    } else
        [m_currentRequest.first() processContentKeyResponse:[PAL::getAVContentKeyResponseClass() contentKeyResponseWithFairPlayStreamingKeyResponseData:responseData.createNSData().get()]];

    // FIXME(rdar://problem/35592277): stash the callback and call it once AVContentKeyResponse supports a success callback.
    struct objc_method_description method = protocol_getMethodDescription(@protocol(AVContentKeySessionDelegate), @selector(contentKeySession:contentKeyRequestDidSucceed:), NO, YES);
    if (!method.name) {
        KeyStatusVector keyStatuses;
        keyStatuses.reserveInitialCapacity(1);
        keyStatuses.uncheckedAppend(std::make_pair(WTFMove(keyIDs.first()), KeyStatus::Usable));
        callback(false, makeOptional(WTFMove(keyStatuses)), WTF::nullopt, WTF::nullopt, Succeeded);
        return;
    }

    m_updateLicenseCallback = WTFMove(callback);
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::loadSession(LicenseType licenseType, const String& sessionId, const String& origin, LoadSessionCallback&& callback)
{
    UNUSED_PARAM(origin);
    if (licenseType == LicenseType::PersistentUsageRecord) {
        auto* storageURL = m_instance->storageURL();
        if (!m_instance->persistentStateAllowed() || storageURL) {
            callback(WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed, SessionLoadFailure::MismatchedSessionType);
            return;
        }
        auto* certificate = m_instance->serverCertificate();
        if (!certificate) {
            callback(WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed, SessionLoadFailure::NoSessionData);
            return;
        }

        RetainPtr<NSData> appIdentifier = certificate->createNSData();
        KeyStatusVector changedKeys;
        for (NSData* expiredSessionData in [PAL::getAVContentKeySessionClass() pendingExpiredSessionReportsWithAppIdentifier:appIdentifier.get() storageDirectoryAtURL:storageURL]) {
            NSDictionary *expiredSession = [NSPropertyListSerialization propertyListWithData:expiredSessionData options:kCFPropertyListImmutable format:nullptr error:nullptr];
            NSString *playbackSessionIdValue = (NSString *)[expiredSession objectForKey:PlaybackSessionIdKey];
            if (![playbackSessionIdValue isKindOfClass:[NSString class]])
                continue;

            if (sessionId == String(playbackSessionIdValue)) {
                // FIXME(rdar://problem/35934922): use key values stored in expired session report once available
                changedKeys.append((KeyStatusVector::ValueType){ SharedBuffer::create(), KeyStatus::Released });
                m_expiredSessions.append(expiredSessionData);
            }
        }

        if (changedKeys.isEmpty()) {
            callback(WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed, SessionLoadFailure::NoSessionData);
            return;
        }

        callback(WTFMove(changedKeys), WTF::nullopt, WTF::nullopt, Succeeded, SessionLoadFailure::None);
    }
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::closeSession(const String&, CloseSessionCallback&& callback)
{
    if (m_requestLicenseCallback) {
        m_requestLicenseCallback(SharedBuffer::create(), m_sessionId, false, Failed);
        ASSERT(!m_requestLicenseCallback);
    }
    if (m_updateLicenseCallback) {
        m_updateLicenseCallback(true, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
        ASSERT(!m_updateLicenseCallback);
    }
    if (m_removeSessionDataCallback) {
        m_removeSessionDataCallback({ }, WTF::nullopt, Failed);
        ASSERT(!m_removeSessionDataCallback);
    }
    m_currentRequest.clear();
    m_pendingRequests.clear();
    m_requests.clear();
    callback();
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::removeSessionData(const String& sessionId, LicenseType licenseType, RemoveSessionDataCallback&& callback)
{
    // FIXME: We should be able to expire individual AVContentKeyRequests rather than the entire AVContentKeySession.
    [m_session expire];

    if (licenseType == LicenseType::PersistentUsageRecord) {
        auto* storageURL = m_instance->storageURL();
        auto* certificate = m_instance->serverCertificate();

        if (!m_instance->persistentStateAllowed() || !storageURL || !certificate) {
            callback({ }, WTF::nullopt, Failed);
            return;
        }

        RetainPtr<NSData> appIdentifier = certificate->createNSData();
        RetainPtr<NSMutableArray> expiredSessionsArray = adoptNS([[NSMutableArray alloc] init]);
        KeyStatusVector changedKeys;
        for (NSData* expiredSessionData in [PAL::getAVContentKeySessionClass() pendingExpiredSessionReportsWithAppIdentifier:appIdentifier.get() storageDirectoryAtURL:storageURL]) {
            NSDictionary *expiredSession = [NSPropertyListSerialization propertyListWithData:expiredSessionData options:kCFPropertyListImmutable format:nullptr error:nullptr];
            NSString *playbackSessionIdValue = (NSString *)[expiredSession objectForKey:PlaybackSessionIdKey];
            if (![playbackSessionIdValue isKindOfClass:[NSString class]])
                continue;

            if (sessionId == String(playbackSessionIdValue)) {
                // FIXME(rdar://problem/35934922): use key values stored in expired session report once available
                changedKeys.append((KeyStatusVector::ValueType){ SharedBuffer::create(), KeyStatus::Released });
                m_expiredSessions.append(expiredSessionData);
                [expiredSessionsArray addObject:expiredSession];
            }
        }

        RetainPtr<NSData> expiredSessionsData = [NSPropertyListSerialization dataWithPropertyList:expiredSessionsArray.get() format:NSPropertyListBinaryFormat_v1_0 options:kCFPropertyListImmutable error:nullptr];

        callback(WTFMove(changedKeys), SharedBuffer::create(expiredSessionsData.get()), Succeeded);
    }
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::storeRecordOfKeyUsage(const String&)
{
    // no-op; key usage data is stored automatically.
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::setClient(WeakPtr<CDMInstanceSessionClient>&& client)
{
    m_client = WTFMove(client);
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::clearClient()
{
    m_client = nullptr;
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::didProvideRequest(AVContentKeyRequest *request)
{
    if (!m_currentRequest.isEmpty()) {
        m_pendingRequests.append({ retainPtr(request) });
        return;
    }

    m_currentRequest = { retainPtr(request) };

    m_requests.append(m_currentRequest);

    RetainPtr<NSData> appIdentifier;
    if (auto* certificate = m_instance->serverCertificate())
        appIdentifier = certificate->createNSData();

    auto keyIDs = keyIDsForRequest(request);
    if (keyIDs.isEmpty()) {
        if (m_requestLicenseCallback) {
            m_requestLicenseCallback(SharedBuffer::create(), m_sessionId, false, Failed);
            ASSERT(!m_requestLicenseCallback);
        }
        return;
    }

    RetainPtr<NSData> contentIdentifier = keyIDs.first()->createNSData();
    [request makeStreamingContentKeyRequestDataForApp:appIdentifier.get() contentIdentifier:contentIdentifier.get() options:nil completionHandler:[this, weakThis = makeWeakPtr(*this)] (NSData *contentKeyRequestData, NSError *error) mutable {
        callOnMainThread([this, weakThis = WTFMove(weakThis), error = retainPtr(error), contentKeyRequestData = retainPtr(contentKeyRequestData)] {
            if (!weakThis)
                return;

            sessionIdentifierChanged(m_session.get().contentProtectionSessionIdentifier);

            if (error && m_requestLicenseCallback)
                m_requestLicenseCallback(SharedBuffer::create(), m_sessionId, false, Failed);
            else if (m_requestLicenseCallback)
                m_requestLicenseCallback(SharedBuffer::create(contentKeyRequestData.get()), m_sessionId, false, Succeeded);
            else if (m_client)
                m_client->sendMessage(CDMMessageType::LicenseRequest, SharedBuffer::create(contentKeyRequestData.get()));
            ASSERT(!m_requestLicenseCallback);
        });
    }];
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::didProvideRequests(Vector<RetainPtr<AVContentKeyRequest>>&& requests)
{
    if (!m_currentRequest.isEmpty()) {
        m_pendingRequests.append(WTFMove(requests));
        return;
    }

    m_currentRequest = requests;
    m_requests.append(WTFMove(requests));

    RetainPtr<NSData> appIdentifier;
    if (auto* certificate = m_instance->serverCertificate())
        appIdentifier = certificate->createNSData();

    using RequestsData = Vector<std::pair<RefPtr<SharedBuffer>, RetainPtr<NSData>>>;
    struct CallbackAggregator final : public ThreadSafeRefCounted<CallbackAggregator> {
        using CallbackFunction = Function<void(RequestsData&&)>;
        static RefPtr<CallbackAggregator> create(CallbackFunction&& completionHandler)
        {
            return adoptRef(new CallbackAggregator(WTFMove(completionHandler)));
        }

        explicit CallbackAggregator(Function<void(RequestsData&&)>&& completionHandler)
            : m_completionHandler(WTFMove(completionHandler))
        {
        }

        ~CallbackAggregator()
        {
            callOnMainThread([completionHandler = WTFMove(m_completionHandler), requestsData = WTFMove(requestsData)] () mutable {
                completionHandler(WTFMove(requestsData));
            });
        }

        CompletionHandler<void(RequestsData&&)> m_completionHandler;
        RequestsData requestsData;
    };

    auto aggregator = CallbackAggregator::create([this, weakThis = makeWeakPtr(*this)] (RequestsData&& requestsData) {
        if (!weakThis)
            return;

        if (!m_requestLicenseCallback)
            return;

        if (requestsData.isEmpty()) {
            m_requestLicenseCallback(SharedBuffer::create(), m_sessionId, false, Failed);
            return;
        }

        auto requestJSON = JSON::Array::create();
        for (auto& requestData : requestsData) {
            auto entry = JSON::Object::create();
            auto& keyID = requestData.first;
            auto& payload = requestData.second;
            entry->setString("keyID", base64Encode(keyID->data(), keyID->size()));
            entry->setString("payload", base64Encode(payload.get().bytes, payload.get().length));
            requestJSON->pushObject(WTFMove(entry));
        }
        auto requestBuffer = utf8Buffer(requestJSON->toJSONString());
        if (!requestBuffer) {
            m_requestLicenseCallback(SharedBuffer::create(), m_sessionId, false, Failed);
            return;
        }
        m_requestLicenseCallback(requestBuffer.releaseNonNull(), m_sessionId, false, Succeeded);
    });

    for (auto request : m_currentRequest) {
        auto keyIDs = keyIDsForRequest(request.get());
        RefPtr<SharedBuffer> keyID = WTFMove(keyIDs.first());
        auto contentIdentifier = keyID->createNSData();
        [request makeStreamingContentKeyRequestDataForApp:appIdentifier.get() contentIdentifier:contentIdentifier.get() options:nil completionHandler:[keyID = WTFMove(keyID), aggregator = aggregator.copyRef()] (NSData *contentKeyRequestData, NSError *error) mutable {
            UNUSED_PARAM(error);
            callOnMainThread([keyID = WTFMove(keyID), aggregator = WTFMove(aggregator), contentKeyRequestData = retainPtr(contentKeyRequestData)] () mutable {
                aggregator->requestsData.append({ WTFMove(keyID), WTFMove(contentKeyRequestData) });
            });
        }];
    }
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::didProvideRenewingRequest(AVContentKeyRequest *request)
{
    ASSERT(!m_requestLicenseCallback);
    if (!m_currentRequest.isEmpty()) {
        m_pendingRequests.append({ retainPtr(request) });
        return;
    }

    m_currentRequest = { retainPtr(request) };

    // The assumption here is that AVContentKeyRequest will only ever notify us of a renewing request as a result of calling
    // -renewExpiringResponseDataForContentKeyRequest: with an existing request.
    ASSERT(m_requests.contains(m_currentRequest));

    RetainPtr<NSData> appIdentifier;
    if (auto* certificate = m_instance->serverCertificate())
        appIdentifier = certificate->createNSData();
    auto keyIDs = keyIDsForRequest(m_currentRequest);

    RetainPtr<NSData> contentIdentifier = keyIDs.first()->createNSData();
    [request makeStreamingContentKeyRequestDataForApp:appIdentifier.get() contentIdentifier:contentIdentifier.get() options:nil completionHandler:[this, weakThis = makeWeakPtr(*this)] (NSData *contentKeyRequestData, NSError *error) mutable {
        callOnMainThread([this, weakThis = WTFMove(weakThis), error = retainPtr(error), contentKeyRequestData = retainPtr(contentKeyRequestData)] {
            if (!weakThis || !m_client || error)
                return;

            if (error && m_updateLicenseCallback)
                m_updateLicenseCallback(false, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
            else if (m_updateLicenseCallback)
                m_updateLicenseCallback(false, WTF::nullopt, WTF::nullopt, Message(MessageType::LicenseRenewal, SharedBuffer::create(contentKeyRequestData.get())), Succeeded);
            else if (m_client)
                m_client->sendMessage(CDMMessageType::LicenseRenewal, SharedBuffer::create(contentKeyRequestData.get()));
            ASSERT(!m_updateLicenseCallback);
        });
    }];
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::didProvidePersistableRequest(AVContentKeyRequest *request)
{
    UNUSED_PARAM(request);
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::didFailToProvideRequest(AVContentKeyRequest *request, NSError *error)
{
    UNUSED_PARAM(request);
    UNUSED_PARAM(error);

    if (m_updateResponseCollector) {
        m_updateResponseCollector->addErrorResponse(request, error);
        return;
    }

    if (m_updateLicenseCallback) {
        m_updateLicenseCallback(false, WTF::nullopt, WTF::nullopt, WTF::nullopt, Failed);
        ASSERT(!m_updateLicenseCallback);
    }

    m_currentRequest.clear();

    nextRequest();
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::requestDidSucceed(AVContentKeyRequest *request)
{
    UNUSED_PARAM(request);
    if (m_updateResponseCollector) {
        m_updateResponseCollector->addSuccessfulResponse(request, nullptr);
        return;
    }

    if (m_updateLicenseCallback) {
        m_updateLicenseCallback(false, makeOptional(keyStatuses()), WTF::nullopt, WTF::nullopt, Succeeded);
        ASSERT(!m_updateLicenseCallback);
    }

    m_currentRequest.clear();

    nextRequest();
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::nextRequest()
{
    if (m_pendingRequests.isEmpty())
        return;

    Request nextRequest = WTFMove(m_pendingRequests.first());
    m_pendingRequests.remove(0);

    if (nextRequest.isEmpty())
        return;

    if (nextRequest.size() > 1) {
        didProvideRequests(WTFMove(nextRequest));
        return;
    }

    auto* oneRequest = nextRequest.first().get();
    if (oneRequest.renewsExpiringResponseData)
        didProvideRenewingRequest(oneRequest);
    else
        didProvideRequest(oneRequest);
}

AVContentKeyRequest* CDMInstanceSessionFairPlayStreamingAVFObjC::lastKeyRequest() const
{
    if (m_requests.isEmpty())
        return nil;
    auto& lastRequest = m_requests.last();
    if (lastRequest.isEmpty())
        return nil;
    return lastRequest.last().get();
}

bool CDMInstanceSessionFairPlayStreamingAVFObjC::shouldRetryRequestForReason(AVContentKeyRequest *request, NSString *reason)
{
    UNUSED_PARAM(request);
    UNUSED_PARAM(reason);
    notImplemented();
    return false;
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::sessionIdentifierChanged(NSData *sessionIdentifier)
{
    String sessionId = emptyString();
    if (sessionIdentifier)
        sessionId = adoptNS([[NSString alloc] initWithData:sessionIdentifier encoding:NSUTF8StringEncoding]).get();

    if (m_sessionId == sessionId)
        return;

    m_sessionId = sessionId;
    m_client->sessionIdChanged(m_sessionId);
}

static auto requestStatusToCDMStatus(AVContentKeyRequestStatus status)
{
    switch (status) {
        case AVContentKeyRequestStatusRequestingResponse:
        case AVContentKeyRequestStatusRetried:
            return CDMKeyStatus::StatusPending;
        case AVContentKeyRequestStatusReceivedResponse:
        case AVContentKeyRequestStatusRenewed:
            return CDMKeyStatus::Usable;
        case AVContentKeyRequestStatusCancelled:
            return CDMKeyStatus::Released;
        case AVContentKeyRequestStatusFailed:
            return CDMKeyStatus::InternalError;
    }
}

CDMInstanceSession::KeyStatusVector CDMInstanceSessionFairPlayStreamingAVFObjC::keyStatuses() const
{
    KeyStatusVector keyStatuses;

    for (auto& request : m_requests) {
        for (auto& oneRequest : request) {
            auto keyIDs = keyIDsForRequest(oneRequest.get());
            auto status = requestStatusToCDMStatus(oneRequest.get().status);
            if (m_outputObscured)
                status = CDMKeyStatus::OutputRestricted;

            for (auto& keyID : keyIDs)
                keyStatuses.append({ WTFMove(keyID), status });
        }
    }

    return keyStatuses;
}

void CDMInstanceSessionFairPlayStreamingAVFObjC::outputObscuredDueToInsufficientExternalProtectionChanged(bool obscured)
{
    if (obscured == m_outputObscured)
        return;

    m_outputObscured = obscured;

    if (m_client)
        m_client->updateKeyStatuses(keyStatuses());
}

AVContentKeySession* CDMInstanceSessionFairPlayStreamingAVFObjC::ensureSession()
{
    if (m_session)
        return m_session.get();

    auto storageURL = m_instance->storageURL();
    if (!m_instance->persistentStateAllowed() || !storageURL)
        m_session = [PAL::getAVContentKeySessionClass() contentKeySessionWithKeySystem:AVContentKeySystemFairPlayStreaming];
    else
        m_session = [PAL::getAVContentKeySessionClass() contentKeySessionWithKeySystem:AVContentKeySystemFairPlayStreaming storageDirectoryAtURL:storageURL];

    if (!m_session)
        return nullptr;

    [m_session setDelegate:m_delegate.get() queue:dispatch_get_main_queue()];
    return m_session.get();
}

bool CDMInstanceSessionFairPlayStreamingAVFObjC::isLicenseTypeSupported(LicenseType licenseType) const
{
    switch (licenseType) {
    case CDMSessionType::PersistentLicense:
        return m_instance->persistentStateAllowed() && m_instance->supportsPersistentKeys();
    case CDMSessionType::PersistentUsageRecord:
        return m_instance->persistentStateAllowed() && m_instance->supportsPersistableState();
    case CDMSessionType::Temporary:
        return true;
    }
}

}

#endif // ENABLE(ENCRYPTED_MEDIA) && HAVE(AVCONTENTKEYSESSION)
