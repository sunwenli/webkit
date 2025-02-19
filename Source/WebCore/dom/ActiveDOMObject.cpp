/*
 * Copyright (C) 2008 Apple Inc. All Rights Reserved.
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
 *
 */

#include "config.h"
#include "ActiveDOMObject.h"

#include "AbstractEventLoop.h"
#include "Document.h"
#include "ScriptExecutionContext.h"

namespace WebCore {

static inline ScriptExecutionContext* suitableScriptExecutionContext(ScriptExecutionContext* scriptExecutionContext)
{
    // For detached documents, make sure we observe their context document instead.
    return is<Document>(scriptExecutionContext) ? &downcast<Document>(*scriptExecutionContext).contextDocument() : scriptExecutionContext;
}

inline ActiveDOMObject::ActiveDOMObject(ScriptExecutionContext* context, CheckedScriptExecutionContextType)
    : ContextDestructionObserver(context)
{
    ASSERT(!is<Document>(context) || &downcast<Document>(context)->contextDocument() == downcast<Document>(context));
    if (!context)
        return;

    ASSERT(context->isContextThread());
    context->didCreateActiveDOMObject(*this);
}

ActiveDOMObject::ActiveDOMObject(ScriptExecutionContext* scriptExecutionContext)
    : ActiveDOMObject(suitableScriptExecutionContext(scriptExecutionContext), CheckedScriptExecutionContext)
{
}

ActiveDOMObject::ActiveDOMObject(Document* document)
    : ActiveDOMObject(document ? &document->contextDocument() : nullptr, CheckedScriptExecutionContext)
{
}

ActiveDOMObject::ActiveDOMObject(Document& document)
    : ActiveDOMObject(&document.contextDocument(), CheckedScriptExecutionContext)
{
}

ActiveDOMObject::~ActiveDOMObject()
{
    ASSERT(canAccessThreadLocalDataForThread(m_creationThread));

    // ActiveDOMObject may be inherited by a sub-class whose life-cycle
    // exceeds that of the associated ScriptExecutionContext. In those cases,
    // m_scriptExecutionContext would/should have been nullified by
    // ContextDestructionObserver::contextDestroyed() (which we implement /
    // inherit). Hence, we should ensure that this is not 0 before use it
    // here.
    if (!m_scriptExecutionContext)
        return;

    ASSERT(m_suspendIfNeededWasCalled);
    ASSERT(m_scriptExecutionContext->isContextThread());
    m_scriptExecutionContext->willDestroyActiveDOMObject(*this);
}

void ActiveDOMObject::suspendIfNeeded()
{
#if !ASSERT_DISABLED
    ASSERT(!m_suspendIfNeededWasCalled);
    m_suspendIfNeededWasCalled = true;
#endif
    if (!m_scriptExecutionContext)
        return;

    m_scriptExecutionContext->suspendActiveDOMObjectIfNeeded(*this);
}

#if !ASSERT_DISABLED

void ActiveDOMObject::assertSuspendIfNeededWasCalled() const
{
    ASSERT(m_suspendIfNeededWasCalled);
}

#endif

bool ActiveDOMObject::hasPendingActivity() const
{
    return m_pendingActivityCount;
}

void ActiveDOMObject::suspend(ReasonForSuspension)
{
}

void ActiveDOMObject::resume()
{
}

void ActiveDOMObject::stop()
{
}

bool ActiveDOMObject::isContextStopped() const
{
    return !scriptExecutionContext() || scriptExecutionContext()->activeDOMObjectsAreStopped();
}

bool ActiveDOMObject::isAllowedToRunScript() const
{
    return scriptExecutionContext() && !scriptExecutionContext()->activeDOMObjectsAreStopped() && !scriptExecutionContext()->activeDOMObjectsAreSuspended();
}

void ActiveDOMObject::queueTaskInEventLoop(TaskSource source, Function<void ()>&& task)
{
    auto* context = scriptExecutionContext();
    if (!context)
        return;
    context->eventLoop().queueTask(source, *context, WTFMove(task));
}

} // namespace WebCore
