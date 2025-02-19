/*
 * Copyright (C) 2015 Yusuke Suzuki <utatane.tea@gmail.com>.
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

function all(iterable)
{
    "use strict";

    if (!@isObject(this))
        @throwTypeError("|this| is not an object");

    var promiseCapability = @newPromiseCapability(this);

    var values = [];
    var index = 0;
    var remainingElementsCount = 1;

    function newResolveElement(index)
    {
        var alreadyCalled = false;
        return function @resolve(argument)
        {
            if (alreadyCalled)
                return @undefined;
            alreadyCalled = true;

            @putByValDirect(values, index, argument);

            --remainingElementsCount;
            if (remainingElementsCount === 0)
                return promiseCapability.@resolve.@call(@undefined, values);

            return @undefined;
        }
    }

    try {
        var promiseResolve = this.resolve;
        if (typeof promiseResolve !== "function")
            @throwTypeError("Promise resolve is not a function");

        for (var value of iterable) {
            @putByValDirect(values, index, @undefined);
            var nextPromise = promiseResolve.@call(this, value);
            var resolveElement = newResolveElement(index);
            ++remainingElementsCount;
            nextPromise.then(resolveElement, promiseCapability.@reject);
            ++index;
        }

        --remainingElementsCount;
        if (remainingElementsCount === 0)
            promiseCapability.@resolve.@call(@undefined, values);
    } catch (error) {
        promiseCapability.@reject.@call(@undefined, error);
    }

    return promiseCapability.@promise;
}

function allSettled(iterable)
{
    "use strict";

    if (!@isObject(this))
        @throwTypeError("|this| is not an object");

    var promiseCapability = @newPromiseCapability(this);

    var values = [];
    var remainingElementsCount = 1;
    var index = 0;

    function newResolveRejectElements(index)
    {
        var alreadyCalled = false;

        var resolveElement = function @resolve(x)
        {
            if (alreadyCalled)
                return @undefined;
            alreadyCalled = true;

            var obj = {
                status: "fulfilled",
                value: x
            };

            @putByValDirect(values, index, obj);

            --remainingElementsCount;
            if (remainingElementsCount === 0)
                return promiseCapability.@resolve.@call(@undefined, values);

            return @undefined;
        };

        var rejectElement = function @reject(x)
        {
            if (alreadyCalled)
                return @undefined;
            alreadyCalled = true;

            var obj = {
                status: "rejected",
                reason: x
            };

            @putByValDirect(values, index, obj);

            --remainingElementsCount;
            if (remainingElementsCount === 0)
                return promiseCapability.@resolve.@call(@undefined, values);

            return @undefined;
        };

        return [resolveElement, rejectElement];
    }

    try {
        var promiseResolve = this.resolve;
        if (typeof promiseResolve !== "function")
            @throwTypeError("Promise resolve is not a function");

        for (var value of iterable) {
            @putByValDirect(values, index, @undefined);
            var nextPromise = promiseResolve.@call(this, value);
            var [resolveElement, rejectElement] = newResolveRejectElements(index);
            ++remainingElementsCount;
            nextPromise.then(resolveElement, rejectElement);
            ++index;
        }

        --remainingElementsCount;
        if (remainingElementsCount === 0)
            promiseCapability.@resolve.@call(@undefined, values);
    } catch (error) {
        promiseCapability.@reject.@call(@undefined, error);
    }

    return promiseCapability.@promise;
}

function race(iterable)
{
    "use strict";

    if (!@isObject(this))
        @throwTypeError("|this| is not an object");

    var promiseCapability = @newPromiseCapability(this);

    try {
        var promiseResolve = this.resolve;
        if (typeof promiseResolve !== "function")
            @throwTypeError("Promise resolve is not a function");

        for (var value of iterable) {
            var nextPromise = promiseResolve.@call(this, value);
            nextPromise.then(promiseCapability.@resolve, promiseCapability.@reject);
        }
    } catch (error) {
        promiseCapability.@reject.@call(@undefined, error);
    }

    return promiseCapability.@promise;
}

function reject(reason)
{
    "use strict";

    if (!@isObject(this))
        @throwTypeError("|this| is not an object");

    if (this === @Promise) {
        var promise = @newPromise();
        @rejectPromiseWithFirstResolvingFunctionCallCheck(promise, reason);
        return promise;
    }

    return @promiseRejectSlow(this, reason);
}

function resolve(value)
{
    "use strict";

    if (!@isObject(this))
        @throwTypeError("|this| is not an object");

    if (@isPromise(value)) {
        var valueConstructor = value.constructor;
        if (valueConstructor === this)
            return value;
    }

    if (this === @Promise) {
        var promise = @newPromise();
        @resolvePromiseWithFirstResolvingFunctionCallCheck(promise, value);
        return promise;
    }

    return @promiseResolveSlow(this, value);
}

@nakedConstructor
function Promise(executor)
{
    "use strict";

    if (typeof executor !== "function")
        @throwTypeError("Promise constructor takes a function argument");

    var promise = @createPromise(this, /* isInternalPromise */ false);
    var capturedPromise = promise;

    try {
        executor(
            function @resolve(resolution) {
                return @resolvePromiseWithFirstResolvingFunctionCallCheck(capturedPromise, resolution);
            },
            function @reject(reason) {
                return @rejectPromiseWithFirstResolvingFunctionCallCheck(capturedPromise, reason);
            });
    } catch (error) {
        @rejectPromiseWithFirstResolvingFunctionCallCheck(promise, error);
    }

    return promise;
}

@nakedConstructor
function InternalPromise(executor)
{
    "use strict";

    if (typeof executor !== "function")
        @throwTypeError("InternalPromise constructor takes a function argument");

    var promise = @createPromise(this, /* isInternalPromise */ true);
    var capturedPromise = promise;

    try {
        executor(
            function @resolve(resolution) {
                return @resolvePromiseWithFirstResolvingFunctionCallCheck(capturedPromise, resolution);
            },
            function @reject(reason) {
                return @rejectPromiseWithFirstResolvingFunctionCallCheck(capturedPromise, reason);
            });
    } catch (error) {
        @rejectPromiseWithFirstResolvingFunctionCallCheck(promise, error);
    }

    return promise;
}
