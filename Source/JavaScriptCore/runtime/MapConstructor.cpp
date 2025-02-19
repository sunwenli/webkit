/*
 * Copyright (C) 2013-2017 Apple Inc. All rights reserved.
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
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL APPLE INC. OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"
#include "MapConstructor.h"

#include "Error.h"
#include "GetterSetter.h"
#include "IteratorOperations.h"
#include "JSCInlines.h"
#include "JSGlobalObject.h"
#include "JSMap.h"
#include "JSObjectInlines.h"
#include "MapPrototype.h"

namespace JSC {

const ClassInfo MapConstructor::s_info = { "Function", &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(MapConstructor) };

void MapConstructor::finishCreation(VM& vm, MapPrototype* mapPrototype, GetterSetter* speciesSymbol)
{
    Base::finishCreation(vm, "Map"_s, NameVisibility::Visible, NameAdditionMode::WithoutStructureTransition);
    putDirectWithoutTransition(vm, vm.propertyNames->prototype, mapPrototype, PropertyAttribute::DontEnum | PropertyAttribute::DontDelete | PropertyAttribute::ReadOnly);
    putDirectWithoutTransition(vm, vm.propertyNames->length, jsNumber(0), PropertyAttribute::DontEnum | PropertyAttribute::ReadOnly);
    putDirectNonIndexAccessorWithoutTransition(vm, vm.propertyNames->speciesSymbol, speciesSymbol, PropertyAttribute::Accessor | PropertyAttribute::ReadOnly | PropertyAttribute::DontEnum);
}

static EncodedJSValue JSC_HOST_CALL callMap(JSGlobalObject*, CallFrame*);
static EncodedJSValue JSC_HOST_CALL constructMap(JSGlobalObject*, CallFrame*);

MapConstructor::MapConstructor(VM& vm, Structure* structure)
    : Base(vm, structure, callMap, constructMap)
{
}

static EncodedJSValue JSC_HOST_CALL callMap(JSGlobalObject* globalObject, CallFrame*)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSValue::encode(throwConstructorCannotBeCalledAsFunctionTypeError(globalObject, scope, "Map"));
}

static EncodedJSValue JSC_HOST_CALL constructMap(JSGlobalObject* globalObject, CallFrame* callFrame)
{
    VM& vm = globalObject->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    Structure* mapStructure = InternalFunction::createSubclassStructure(globalObject, callFrame->jsCallee(), callFrame->newTarget(), globalObject->mapStructure());
    RETURN_IF_EXCEPTION(scope, encodedJSValue());

    JSValue iterable = callFrame->argument(0);
    if (iterable.isUndefinedOrNull())
        RELEASE_AND_RETURN(scope, JSValue::encode(JSMap::create(globalObject, vm, mapStructure)));

    if (auto* iterableMap = jsDynamicCast<JSMap*>(vm, iterable)) {
        if (iterableMap->canCloneFastAndNonObservable(mapStructure))
            RELEASE_AND_RETURN(scope, JSValue::encode(iterableMap->clone(globalObject, vm, mapStructure)));
    }

    JSMap* map = JSMap::create(globalObject, vm, mapStructure);
    RETURN_IF_EXCEPTION(scope, encodedJSValue());

    JSValue adderFunction = map->JSObject::get(globalObject, vm.propertyNames->set);
    RETURN_IF_EXCEPTION(scope, encodedJSValue());

    CallData adderFunctionCallData;
    CallType adderFunctionCallType = getCallData(vm, adderFunction, adderFunctionCallData);
    if (adderFunctionCallType == CallType::None)
        return JSValue::encode(throwTypeError(globalObject, scope));

    scope.release();
    forEachInIterable(globalObject, iterable, [&](VM& vm, JSGlobalObject* globalObject, JSValue nextItem) {
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!nextItem.isObject()) {
            throwTypeError(globalObject, scope);
            return;
        }

        JSValue key = nextItem.get(globalObject, static_cast<unsigned>(0));
        RETURN_IF_EXCEPTION(scope, void());

        JSValue value = nextItem.get(globalObject, static_cast<unsigned>(1));
        RETURN_IF_EXCEPTION(scope, void());

        MarkedArgumentBuffer arguments;
        arguments.append(key);
        arguments.append(value);
        ASSERT(!arguments.hasOverflowed());
        scope.release();
        call(globalObject, adderFunction, adderFunctionCallType, adderFunctionCallData, map, arguments);
    });

    return JSValue::encode(map);
}

EncodedJSValue JSC_HOST_CALL mapPrivateFuncMapBucketHead(JSGlobalObject* globalObject, CallFrame* callFrame)
{
    ASSERT_UNUSED(globalObject, jsDynamicCast<JSMap*>(globalObject->vm(), callFrame->argument(0)));
    JSMap* map = jsCast<JSMap*>(callFrame->uncheckedArgument(0));
    auto* head = map->head();
    ASSERT(head);
    return JSValue::encode(head);
}

EncodedJSValue JSC_HOST_CALL mapPrivateFuncMapBucketNext(JSGlobalObject* globalObject, CallFrame* callFrame)
{
    ASSERT(jsDynamicCast<JSMap::BucketType*>(globalObject->vm(), callFrame->argument(0)));
    auto* bucket = jsCast<JSMap::BucketType*>(callFrame->uncheckedArgument(0));
    ASSERT(bucket);
    bucket = bucket->next();
    while (bucket) {
        if (!bucket->deleted())
            return JSValue::encode(bucket);
        bucket = bucket->next();
    }
    return JSValue::encode(globalObject->vm().sentinelMapBucket());
}

EncodedJSValue JSC_HOST_CALL mapPrivateFuncMapBucketKey(JSGlobalObject* globalObject, CallFrame* callFrame)
{
    ASSERT_UNUSED(globalObject, jsDynamicCast<JSMap::BucketType*>(globalObject->vm(), callFrame->argument(0)));
    auto* bucket = jsCast<JSMap::BucketType*>(callFrame->uncheckedArgument(0));
    ASSERT(bucket);
    return JSValue::encode(bucket->key());
}

EncodedJSValue JSC_HOST_CALL mapPrivateFuncMapBucketValue(JSGlobalObject* globalObject, CallFrame* callFrame)
{
    ASSERT_UNUSED(globalObject, jsDynamicCast<JSMap::BucketType*>(globalObject->vm(), callFrame->argument(0)));
    auto* bucket = jsCast<JSMap::BucketType*>(callFrame->uncheckedArgument(0));
    ASSERT(bucket);
    return JSValue::encode(bucket->value());
}

}
