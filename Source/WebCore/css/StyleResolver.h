/*
 * Copyright (C) 1999 Lars Knoll (knoll@kde.org)
 * Copyright (C) 2003, 2004, 2005, 2006, 2007, 2008, 2009, 2010, 2011, 2012, 2013 Apple Inc. All rights reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Library General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Library General Public License for more details.
 *
 * You should have received a copy of the GNU Library General Public License
 * along with this library; see the file COPYING.LIB.  If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 */

#pragma once

#include "CSSSelector.h"
#include "DocumentRuleSets.h"
#include "ElementRuleCollector.h"
#include "InspectorCSSOMWrappers.h"
#include "MatchedDeclarationsCache.h"
#include "MediaQueryEvaluator.h"
#include "RenderStyle.h"
#include "RuleSet.h"
#include "StyleBuilderState.h"
#include <memory>
#include <wtf/HashMap.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>
#include <wtf/text/AtomStringHash.h>
#include <wtf/text/StringHash.h>

namespace WebCore {

class CSSCursorImageValue;
class CSSFontFace;
class CSSFontFaceRule;
class CSSFontValue;
class CSSImageGeneratorValue;
class CSSImageSetValue;
class CSSImageValue;
class CSSPageRule;
class CSSPrimitiveValue;
class CSSProperty;
class CSSStyleSheet;
class CSSValue;
class ContainerNode;
class Document;
class Element;
class Frame;
class FrameView;
class KeyframeList;
class KeyframeValue;
class MediaQueryEvaluator;
class Node;
class RuleData;
class RuleSet;
class SelectorFilter;
class Settings;
class StyleCachedImage;
class StyleGeneratedImage;
class StyleImage;
class StyleRuleKeyframe;
class StyleProperties;
class StyleRule;
class StyleRuleKeyframes;
class StyleRulePage;
class StyleSheet;
class StyleSheetList;
class StyledElement;
class SVGElement;
class ViewportStyleResolver;
struct ResourceLoaderOptions;

// MatchOnlyUserAgentRules is used in media queries, where relative units
// are interpreted according to the document root element style, and styled only
// from the User Agent Stylesheet rules.

enum class RuleMatchingBehavior: uint8_t {
    MatchAllRules,
    MatchAllRulesExcludingSMIL,
    MatchOnlyUserAgentRules,
};

struct ElementStyle {
    ElementStyle(std::unique_ptr<RenderStyle> renderStyle, std::unique_ptr<Style::Relations> relations = { })
        : renderStyle(WTFMove(renderStyle))
        , relations(WTFMove(relations))
    { }

    std::unique_ptr<RenderStyle> renderStyle;
    std::unique_ptr<Style::Relations> relations;
};

// This class selects a RenderStyle for a given element based on a collection of stylesheets.
class StyleResolver {
    WTF_MAKE_NONCOPYABLE(StyleResolver); WTF_MAKE_FAST_ALLOCATED;
public:
    StyleResolver(Document&);
    ~StyleResolver();

    ElementStyle styleForElement(const Element&, const RenderStyle* parentStyle, const RenderStyle* parentBoxStyle = nullptr, RuleMatchingBehavior = RuleMatchingBehavior::MatchAllRules, const SelectorFilter* = nullptr);

    void keyframeStylesForAnimation(const Element&, const RenderStyle*, KeyframeList&);

    std::unique_ptr<RenderStyle> pseudoStyleForElement(const Element&, const PseudoStyleRequest&, const RenderStyle& parentStyle, const RenderStyle* parentBoxStyle = nullptr, const SelectorFilter* = nullptr);

    std::unique_ptr<RenderStyle> styleForPage(int pageIndex);
    std::unique_ptr<RenderStyle> defaultStyleForElement(const Element*);

    Document& document() { return m_document; }
    const Document& document() const { return m_document; }
    const Settings& settings() const { return m_document.settings(); }

    void appendAuthorStyleSheets(const Vector<RefPtr<CSSStyleSheet>>&);

    DocumentRuleSets& ruleSets() { return m_ruleSets; }
    const DocumentRuleSets& ruleSets() const { return m_ruleSets; }

    const MediaQueryEvaluator& mediaQueryEvaluator() const { return m_mediaQueryEvaluator; }

    RenderStyle* overrideDocumentElementStyle() const { return m_overrideDocumentElementStyle; }
    void setOverrideDocumentElementStyle(RenderStyle* style) { m_overrideDocumentElementStyle = style; }

    void addCurrentSVGFontFaceRules();

    std::unique_ptr<RenderStyle> styleForKeyframe(const Element&, const RenderStyle*, const StyleRuleKeyframe*, KeyframeValue&);
    bool isAnimationNameValid(const String&);

    // These methods will give back the set of rules that matched for a given element (or a pseudo-element).
    enum CSSRuleFilter {
        UAAndUserCSSRules   = 1 << 1,
        AuthorCSSRules      = 1 << 2,
        EmptyCSSRules       = 1 << 3,
        AllButEmptyCSSRules = UAAndUserCSSRules | AuthorCSSRules,
        AllCSSRules         = AllButEmptyCSSRules | EmptyCSSRules,
    };
    Vector<RefPtr<StyleRule>> styleRulesForElement(const Element*, unsigned rulesToInclude = AllButEmptyCSSRules);
    Vector<RefPtr<StyleRule>> pseudoStyleRulesForElement(const Element*, PseudoId, unsigned rulesToInclude = AllButEmptyCSSRules);

    bool hasSelectorForId(const AtomString&) const;
    bool hasSelectorForAttribute(const Element&, const AtomString&) const;

#if ENABLE(CSS_DEVICE_ADAPTATION)
    ViewportStyleResolver* viewportStyleResolver() { return m_viewportStyleResolver.get(); }
#endif

    void addViewportDependentMediaQueryResult(const MediaQueryExpression&, bool result);
    bool hasViewportDependentMediaQueries() const { return !m_viewportDependentMediaQueryResults.isEmpty(); }
    bool hasMediaQueriesAffectedByViewportChange() const;

    void addAccessibilitySettingsDependentMediaQueryResult(const MediaQueryExpression&, bool result);
    bool hasAccessibilitySettingsDependentMediaQueries() const { return !m_accessibilitySettingsDependentMediaQueryResults.isEmpty(); }
    bool hasMediaQueriesAffectedByAccessibilitySettingsChange() const;

    void addAppearanceDependentMediaQueryResult(const MediaQueryExpression&, bool result);
    bool hasAppearanceDependentMediaQueries() const { return !m_appearanceDependentMediaQueryResults.isEmpty(); }
    bool hasMediaQueriesAffectedByAppearanceChange() const;

    void addKeyframeStyle(Ref<StyleRuleKeyframes>&&);

    bool usesFirstLineRules() const { return m_ruleSets.features().usesFirstLineRules; }
    bool usesFirstLetterRules() const { return m_ruleSets.features().usesFirstLetterRules; }
    
    void invalidateMatchedDeclarationsCache();
    void clearCachedDeclarationsAffectedByViewportUnits();

    InspectorCSSOMWrappers& inspectorCSSOMWrappers() { return m_inspectorCSSOMWrappers; }

private:
    friend class PageRuleCollector;

    class State {
    public:
        State() { }
        State(const Element&, const RenderStyle* parentStyle, const RenderStyle* documentElementStyle = nullptr);

    public:
        const Element* element() const { return m_element; }

        void setStyle(std::unique_ptr<RenderStyle>);
        RenderStyle* style() const { return m_style.get(); }
        std::unique_ptr<RenderStyle> takeStyle() { return WTFMove(m_style); }

        void setParentStyle(std::unique_ptr<RenderStyle>);
        const RenderStyle* parentStyle() const { return m_parentStyle; }
        const RenderStyle* rootElementStyle() const { return m_rootElementStyle; }

        const RenderStyle* userAgentAppearanceStyle() const { return m_userAgentAppearanceStyle.get(); }
        void setUserAgentAppearanceStyle(std::unique_ptr<RenderStyle> style) { m_userAgentAppearanceStyle = WTFMove(style); }

    private:
        const Element* m_element { nullptr };
        std::unique_ptr<RenderStyle> m_style;
        const RenderStyle* m_parentStyle { nullptr };
        std::unique_ptr<const RenderStyle> m_ownedParentStyle;
        const RenderStyle* m_rootElementStyle { nullptr };

        std::unique_ptr<RenderStyle> m_userAgentAppearanceStyle;
    };

    Style::BuilderContext builderContext(const State&);

    enum class UseMatchedDeclarationsCache { Yes, No };
    void applyMatchedProperties(State&, const MatchResult&, UseMatchedDeclarationsCache = UseMatchedDeclarationsCache::Yes);

    DocumentRuleSets m_ruleSets;

    typedef HashMap<AtomStringImpl*, RefPtr<StyleRuleKeyframes>> KeyframesRuleMap;
    KeyframesRuleMap m_keyframesRuleMap;

    MediaQueryEvaluator m_mediaQueryEvaluator;
    std::unique_ptr<RenderStyle> m_rootDefaultStyle;

    Document& m_document;

    RenderStyle* m_overrideDocumentElementStyle { nullptr };

    Vector<MediaQueryResult> m_viewportDependentMediaQueryResults;
    Vector<MediaQueryResult> m_accessibilitySettingsDependentMediaQueryResults;
    Vector<MediaQueryResult> m_appearanceDependentMediaQueryResults;

#if ENABLE(CSS_DEVICE_ADAPTATION)
    RefPtr<ViewportStyleResolver> m_viewportStyleResolver;
#endif

    InspectorCSSOMWrappers m_inspectorCSSOMWrappers;

    Style::MatchedDeclarationsCache m_matchedDeclarationsCache;

    bool m_matchAuthorAndUserStyles { true };
    // See if we still have crashes where StyleResolver gets deleted early.
    bool m_isDeleted { false };
};

inline bool StyleResolver::hasSelectorForAttribute(const Element& element, const AtomString &attributeName) const
{
    ASSERT(!attributeName.isEmpty());
    if (element.isHTMLElement())
        return m_ruleSets.features().attributeCanonicalLocalNamesInRules.contains(attributeName);
    return m_ruleSets.features().attributeLocalNamesInRules.contains(attributeName);
}

inline bool StyleResolver::hasSelectorForId(const AtomString& idValue) const
{
    ASSERT(!idValue.isEmpty());
    return m_ruleSets.features().idsInRules.contains(idValue);
}

} // namespace WebCore
