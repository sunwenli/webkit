/*
 * Copyright (C) 2013 Apple Inc. All rights reserved.
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

#pragma once

#include "AbstractEventLoop.h"
#include "ExceptionOr.h"
#include "JSDOMConvert.h"
#include "JSDOMGuardedObject.h"
#include "ScriptExecutionContext.h"
#include <JavaScriptCore/CatchScope.h>
#include <JavaScriptCore/JSPromise.h>

namespace WebCore {

class JSDOMWindow;

class DeferredPromise : public DOMGuarded<JSC::JSPromise> {
public:
    enum class Mode {
        ClearPromiseOnResolve,
        RetainPromiseOnResolve
    };

    static RefPtr<DeferredPromise> create(JSDOMGlobalObject& globalObject, Mode mode = Mode::ClearPromiseOnResolve)
    {
        JSC::VM& vm = JSC::getVM(&globalObject);
        auto* promise = JSC::JSPromise::create(vm, globalObject.promiseStructure());
        ASSERT(promise);
        return adoptRef(new DeferredPromise(globalObject, *promise, mode));
    }

    static Ref<DeferredPromise> create(JSDOMGlobalObject& globalObject, JSC::JSPromise& deferred, Mode mode = Mode::ClearPromiseOnResolve)
    {
        return adoptRef(*new DeferredPromise(globalObject, deferred, mode));
    }

    template<class IDLType>
    void resolve(typename IDLType::ParameterType value)
    {
        if (shouldIgnoreRequestToFulfill())
            return;

        ASSERT(deferred());
        ASSERT(globalObject());
        JSC::JSGlobalObject* lexicalGlobalObject = globalObject();
        JSC::JSLockHolder locker(lexicalGlobalObject);
        resolve(*lexicalGlobalObject, toJS<IDLType>(*lexicalGlobalObject, *globalObject(), std::forward<typename IDLType::ParameterType>(value)));
    }

    void resolve()
    {
        if (shouldIgnoreRequestToFulfill())
            return;

        ASSERT(deferred());
        ASSERT(globalObject());
        JSC::JSGlobalObject* lexicalGlobalObject = globalObject();
        JSC::JSLockHolder locker(lexicalGlobalObject);
        resolve(*lexicalGlobalObject, JSC::jsUndefined());
    }

    template<class IDLType>
    void resolveWithNewlyCreated(typename IDLType::ParameterType value)
    {
        if (shouldIgnoreRequestToFulfill())
            return;

        ASSERT(deferred());
        ASSERT(globalObject());
        JSC::JSGlobalObject* lexicalGlobalObject = globalObject();
        JSC::JSLockHolder locker(lexicalGlobalObject);
        resolve(*lexicalGlobalObject, toJSNewlyCreated<IDLType>(*lexicalGlobalObject, *globalObject(), std::forward<typename IDLType::ParameterType>(value)));
    }

    template<class IDLType>
    void resolveCallbackValueWithNewlyCreated(const Function<typename IDLType::InnerParameterType(ScriptExecutionContext&)>& createValue)
    {
        if (shouldIgnoreRequestToFulfill())
            return;

        ASSERT(deferred());
        ASSERT(globalObject());
        auto* lexicalGlobalObject = globalObject();
        JSC::JSLockHolder locker(lexicalGlobalObject);
        resolve(*lexicalGlobalObject, toJSNewlyCreated<IDLType>(*lexicalGlobalObject, *globalObject(), createValue(*globalObject()->scriptExecutionContext())));
    }

    template<class IDLType>
    void reject(typename IDLType::ParameterType value)
    {
        if (shouldIgnoreRequestToFulfill())
            return;

        ASSERT(deferred());
        ASSERT(globalObject());
        JSC::JSGlobalObject* lexicalGlobalObject = globalObject();
        JSC::JSLockHolder locker(lexicalGlobalObject);
        reject(*lexicalGlobalObject, toJS<IDLType>(*lexicalGlobalObject, *globalObject(), std::forward<typename IDLType::ParameterType>(value)));
    }

    void reject();
    void reject(std::nullptr_t);
    void reject(Exception);
    WEBCORE_EXPORT void reject(ExceptionCode, const String& = { });
    void reject(const JSC::PrivateName&);

    template<typename Callback>
    void resolveWithCallback(Callback callback)
    {
        if (shouldIgnoreRequestToFulfill())
            return;

        ASSERT(deferred());
        ASSERT(globalObject());
        JSC::JSGlobalObject* lexicalGlobalObject = globalObject();
        JSC::JSLockHolder locker(lexicalGlobalObject);
        resolve(*lexicalGlobalObject, callback(*globalObject()));
    }

    template<typename Callback>
    void rejectWithCallback(Callback callback)
    {
        if (shouldIgnoreRequestToFulfill())
            return;

        ASSERT(deferred());
        ASSERT(globalObject());
        JSC::JSGlobalObject* lexicalGlobalObject = globalObject();
        JSC::JSLockHolder locker(lexicalGlobalObject);
        reject(*lexicalGlobalObject, callback(*globalObject()));
    }

    JSC::JSValue promise() const;

    void whenSettled(Function<void()>&&);

private:
    DeferredPromise(JSDOMGlobalObject& globalObject, JSC::JSPromise& deferred, Mode mode)
        : DOMGuarded<JSC::JSPromise>(globalObject, deferred)
        , m_mode(mode)
    {
    }

    bool shouldIgnoreRequestToFulfill() const { return isEmpty() || activeDOMObjectAreStopped(); }

    JSC::JSPromise* deferred() const { return guarded(); }

    enum class ResolveMode { Resolve, Reject };
    WEBCORE_EXPORT void callFunction(JSC::JSGlobalObject&, ResolveMode, JSC::JSValue resolution);

    void resolve(JSC::JSGlobalObject& lexicalGlobalObject, JSC::JSValue resolution) { callFunction(lexicalGlobalObject, ResolveMode::Resolve, resolution); }
    void reject(JSC::JSGlobalObject& lexicalGlobalObject, JSC::JSValue resolution) { callFunction(lexicalGlobalObject, ResolveMode::Reject, resolution); }

    Mode m_mode;
};

class DOMPromiseDeferredBase {
    WTF_MAKE_FAST_ALLOCATED;
public:
    DOMPromiseDeferredBase(Ref<DeferredPromise>&& genericPromise)
        : m_promise(WTFMove(genericPromise))
    {
    }

    DOMPromiseDeferredBase(DOMPromiseDeferredBase&& promise)
        : m_promise(WTFMove(promise.m_promise))
    {
    }

    DOMPromiseDeferredBase(const DOMPromiseDeferredBase& other)
        : m_promise(other.m_promise.copyRef())
    {
    }

    DOMPromiseDeferredBase& operator=(const DOMPromiseDeferredBase& other)
    {
        m_promise = other.m_promise.copyRef();
        return *this;
    }

    DOMPromiseDeferredBase& operator=(DOMPromiseDeferredBase&& other)
    {
        m_promise = WTFMove(other.m_promise);
        return *this;
    }

    void reject()
    {
        m_promise->reject();
    }

    template<typename... ErrorType> 
    void reject(ErrorType&&... error)
    {
        m_promise->reject(std::forward<ErrorType>(error)...);
    }

    template<typename IDLType>
    void rejectType(typename IDLType::ParameterType value)
    {
        m_promise->reject<IDLType>(std::forward<typename IDLType::ParameterType>(value));
    }

    JSC::JSValue promise() const { return m_promise->promise(); };

    void whenSettled(Function<void()>&& function)
    {
        m_promise->whenSettled(WTFMove(function));
    }

protected:
    Ref<DeferredPromise> m_promise;
};

template<typename IDLType> 
class DOMPromiseDeferred : public DOMPromiseDeferredBase {
public:
    using DOMPromiseDeferredBase::DOMPromiseDeferredBase;
    using DOMPromiseDeferredBase::operator=;
    using DOMPromiseDeferredBase::promise;
    using DOMPromiseDeferredBase::reject;

    void resolve(typename IDLType::ParameterType value)
    { 
        m_promise->resolve<IDLType>(std::forward<typename IDLType::ParameterType>(value));
    }

    void settle(ExceptionOr<typename IDLType::ParameterType>&& result)
    {
        if (result.hasException()) {
            reject(result.releaseException());
            return;
        }
        resolve(result.releaseReturnValue());
    }
};

template<> class DOMPromiseDeferred<void> : public DOMPromiseDeferredBase {
public:
    using DOMPromiseDeferredBase::DOMPromiseDeferredBase;
    using DOMPromiseDeferredBase::operator=;
    using DOMPromiseDeferredBase::promise;
    using DOMPromiseDeferredBase::reject;

    void resolve()
    { 
        m_promise->resolve();
    }

    void settle(ExceptionOr<void>&& result)
    {
        if (result.hasException()) {
            reject(result.releaseException());
            return;
        }
        resolve();
    }
};


Ref<DeferredPromise> createDeferredPromise(JSC::JSGlobalObject&, JSDOMWindow&);

void fulfillPromiseWithJSON(Ref<DeferredPromise>&&, const String&);
void fulfillPromiseWithArrayBuffer(Ref<DeferredPromise>&&, ArrayBuffer*);
void fulfillPromiseWithArrayBuffer(Ref<DeferredPromise>&&, const void*, size_t);
WEBCORE_EXPORT void rejectPromiseWithExceptionIfAny(JSC::JSGlobalObject&, JSDOMGlobalObject&, JSC::JSPromise&);

enum class RejectedPromiseWithTypeErrorCause { NativeGetter, InvalidThis };
JSC::EncodedJSValue createRejectedPromiseWithTypeError(JSC::JSGlobalObject&, const String&, RejectedPromiseWithTypeErrorCause);

using PromiseFunction = void(JSC::JSGlobalObject&, JSC::CallFrame&, Ref<DeferredPromise>&&);

template<PromiseFunction promiseFunction>
inline JSC::JSValue callPromiseFunction(JSC::JSGlobalObject& lexicalGlobalObject, JSC::CallFrame& callFrame)
{
    JSC::VM& vm = JSC::getVM(&lexicalGlobalObject);
    auto scope = DECLARE_CATCH_SCOPE(vm);

    auto& globalObject = callerGlobalObject(lexicalGlobalObject, callFrame);
    auto* promise = JSC::JSPromise::create(vm, globalObject.promiseStructure());
    ASSERT(promise);

    promiseFunction(lexicalGlobalObject, callFrame, DeferredPromise::create(globalObject, *promise));

    rejectPromiseWithExceptionIfAny(lexicalGlobalObject, globalObject, *promise);
    // FIXME: We could have error since any JS call can throw stack-overflow errors.
    // https://bugs.webkit.org/show_bug.cgi?id=203402
    RETURN_IF_EXCEPTION(scope, JSC::jsUndefined());
    return promise;
}

template<typename PromiseFunctor>
inline JSC::JSValue callPromiseFunction(JSC::JSGlobalObject& lexicalGlobalObject, JSC::CallFrame& callFrame, PromiseFunctor functor)
{
    JSC::VM& vm = JSC::getVM(&lexicalGlobalObject);
    auto scope = DECLARE_CATCH_SCOPE(vm);

    auto& globalObject = callerGlobalObject(lexicalGlobalObject, callFrame);
    auto* promise = JSC::JSPromise::create(vm, globalObject.promiseStructure());
    ASSERT(promise);

    functor(lexicalGlobalObject, callFrame, DeferredPromise::create(globalObject, *promise));

    rejectPromiseWithExceptionIfAny(lexicalGlobalObject, globalObject, *promise);
    // FIXME: We could have error since any JS call can throw stack-overflow errors.
    // https://bugs.webkit.org/show_bug.cgi?id=203402
    RETURN_IF_EXCEPTION(scope, JSC::jsUndefined());
    return promise;
}

using BindingPromiseFunction = JSC::EncodedJSValue(JSC::JSGlobalObject*, JSC::CallFrame*, Ref<DeferredPromise>&&);
template<BindingPromiseFunction bindingFunction>
inline void bindingPromiseFunctionAdapter(JSC::JSGlobalObject& lexicalGlobalObject, JSC::CallFrame& callFrame, Ref<DeferredPromise>&& promise)
{
    bindingFunction(&lexicalGlobalObject, &callFrame, WTFMove(promise));
}

template<BindingPromiseFunction bindingPromiseFunction>
inline JSC::JSValue callPromiseFunction(JSC::JSGlobalObject& lexicalGlobalObject, JSC::CallFrame& callFrame)
{
    return callPromiseFunction<bindingPromiseFunctionAdapter<bindingPromiseFunction>>(lexicalGlobalObject, callFrame);
}

} // namespace WebCore
