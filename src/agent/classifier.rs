use crate::config::schema::{
    ClassificationRule, QueryClassificationConfig, ToolProfile, ToolProfileName,
};
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClassificationDecision {
    pub hint: String,
    pub priority: i32,
    pub tool_profile: Option<ToolProfile>,
}

/// Classify a user message against the configured rules and return the
/// matching hint string, if any.
///
/// Returns `None` when classification is disabled, no rules are configured,
/// or no rule matches the message.
pub fn classify(config: &QueryClassificationConfig, message: &str) -> Option<String> {
    classify_with_decision(config, message).map(|decision| decision.hint)
}

/// Classify a user message and return the matched hint together with
/// match metadata for observability.
pub fn classify_with_decision(
    config: &QueryClassificationConfig,
    message: &str,
) -> Option<ClassificationDecision> {
    if !config.enabled || config.rules.is_empty() {
        return None;
    }

    let lower = message.to_lowercase();
    let len = message.len();

    let mut rules: Vec<_> = config.rules.iter().collect();
    rules.sort_by(|a, b| b.priority.cmp(&a.priority));

    for rule in rules {
        // Length constraints
        if let Some(min) = rule.min_length {
            if len < min {
                continue;
            }
        }
        if let Some(max) = rule.max_length {
            if len > max {
                continue;
            }
        }

        // Check keywords (case-insensitive) and patterns (case-sensitive)
        let keyword_hit = rule
            .keywords
            .iter()
            .any(|kw: &String| lower.contains(&kw.to_lowercase()));
        let pattern_hit = rule
            .patterns
            .iter()
            .any(|pat: &String| message.contains(pat.as_str()));

        if keyword_hit || pattern_hit {
            return Some(ClassificationDecision {
                hint: rule.hint.clone(),
                priority: rule.priority,
                tool_profile: rule.tool_profile.clone(),
            });
        }
    }

    None
}

pub fn default_tool_classification_rules() -> &'static [ClassificationRule] {
    static RULES: OnceLock<Vec<ClassificationRule>> = OnceLock::new();
    RULES.get_or_init(|| {
        vec![
            ClassificationRule {
                hint: "simple".into(),
                keywords: vec![
                    "hello".into(),
                    "hi".into(),
                    "hey".into(),
                    "time".into(),
                    "date".into(),
                    "weather".into(),
                    "thanks".into(),
                    "thank you".into(),
                ],
                max_length: Some(50),
                priority: 1,
                tool_profile: Some(ToolProfile::Named(ToolProfileName::Minimal)),
                ..Default::default()
            },
            ClassificationRule {
                hint: "moderate".into(),
                keywords: vec![
                    "explain".into(),
                    "compare".into(),
                    "analyze".into(),
                    "debug".into(),
                    "write code".into(),
                    "how does".into(),
                    "how to".into(),
                    "why does".into(),
                    "architect".into(),
                    "design".into(),
                    "optimize".into(),
                    "refactor".into(),
                ],
                min_length: Some(50),
                priority: 5,
                ..Default::default()
            },
            ClassificationRule {
                hint: "skill".into(),
                keywords: vec!["run skill".into()],
                priority: 8,
                tool_profile: Some(ToolProfile::Named(ToolProfileName::SkillRunner)),
                ..Default::default()
            },
        ]
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_config(enabled: bool, rules: Vec<ClassificationRule>) -> QueryClassificationConfig {
        QueryClassificationConfig { enabled, rules }
    }

    #[test]
    fn disabled_returns_none() {
        let config = make_config(
            false,
            vec![ClassificationRule {
                hint: "fast".into(),
                keywords: vec!["hello".into()],
                ..Default::default()
            }],
        );
        assert_eq!(classify(&config, "hello"), None);
    }

    #[test]
    fn empty_rules_returns_none() {
        let config = make_config(true, vec![]);
        assert_eq!(classify(&config, "hello"), None);
    }

    #[test]
    fn keyword_match_case_insensitive() {
        let config = make_config(
            true,
            vec![ClassificationRule {
                hint: "fast".into(),
                keywords: vec!["hello".into()],
                ..Default::default()
            }],
        );
        assert_eq!(classify(&config, "HELLO world"), Some("fast".into()));
    }

    #[test]
    fn pattern_match_case_sensitive() {
        let config = make_config(
            true,
            vec![ClassificationRule {
                hint: "code".into(),
                patterns: vec!["fn ".into()],
                ..Default::default()
            }],
        );
        assert_eq!(classify(&config, "fn main()"), Some("code".into()));
        assert_eq!(classify(&config, "FN MAIN()"), None);
    }

    #[test]
    fn length_constraints() {
        let config = make_config(
            true,
            vec![ClassificationRule {
                hint: "fast".into(),
                keywords: vec!["hi".into()],
                max_length: Some(10),
                ..Default::default()
            }],
        );
        assert_eq!(classify(&config, "hi"), Some("fast".into()));
        assert_eq!(
            classify(&config, "hi there, how are you doing today?"),
            None
        );

        let config2 = make_config(
            true,
            vec![ClassificationRule {
                hint: "reasoning".into(),
                keywords: vec!["explain".into()],
                min_length: Some(20),
                ..Default::default()
            }],
        );
        assert_eq!(classify(&config2, "explain"), None);
        assert_eq!(
            classify(&config2, "explain how this works in detail"),
            Some("reasoning".into())
        );
    }

    #[test]
    fn priority_ordering() {
        let config = make_config(
            true,
            vec![
                ClassificationRule {
                    hint: "fast".into(),
                    keywords: vec!["code".into()],
                    priority: 1,
                    ..Default::default()
                },
                ClassificationRule {
                    hint: "code".into(),
                    keywords: vec!["code".into()],
                    priority: 10,
                    ..Default::default()
                },
            ],
        );
        assert_eq!(classify(&config, "write some code"), Some("code".into()));
    }

    #[test]
    fn no_match_returns_none() {
        let config = make_config(
            true,
            vec![ClassificationRule {
                hint: "fast".into(),
                keywords: vec!["hello".into()],
                ..Default::default()
            }],
        );
        assert_eq!(classify(&config, "something completely different"), None);
    }

    #[test]
    fn classify_with_decision_exposes_priority_of_matched_rule() {
        let config = make_config(
            true,
            vec![
                ClassificationRule {
                    hint: "fast".into(),
                    keywords: vec!["code".into()],
                    priority: 3,
                    ..Default::default()
                },
                ClassificationRule {
                    hint: "code".into(),
                    keywords: vec!["code".into()],
                    priority: 10,
                    ..Default::default()
                },
            ],
        );

        let decision = classify_with_decision(&config, "write code now")
            .expect("classification decision expected");
        assert_eq!(decision.hint, "code");
        assert_eq!(decision.priority, 10);
        assert_eq!(decision.tool_profile, None);
    }

    #[test]
    fn classify_returns_tool_profile_when_rule_specifies_one() {
        let config = make_config(
            true,
            vec![ClassificationRule {
                hint: "fast".into(),
                keywords: vec!["hello".into()],
                tool_profile: Some(ToolProfile::Named(ToolProfileName::Minimal)),
                ..Default::default()
            }],
        );

        let decision = classify_with_decision(&config, "hello world")
            .expect("classification decision expected");
        assert_eq!(decision.hint, "fast");
        assert_eq!(
            decision.tool_profile,
            Some(ToolProfile::Named(ToolProfileName::Minimal))
        );
    }

    #[test]
    fn classify_returns_none_tool_profile_when_rule_omits_it() {
        let config = make_config(
            true,
            vec![ClassificationRule {
                hint: "fast".into(),
                keywords: vec!["hello".into()],
                ..Default::default()
            }],
        );

        let decision = classify_with_decision(&config, "hello world")
            .expect("classification decision expected");
        assert_eq!(decision.tool_profile, None);
    }

    #[test]
    fn default_classification_rules_route_simple_queries_to_minimal() {
        let config = QueryClassificationConfig {
            enabled: true,
            rules: default_tool_classification_rules().to_vec(),
        };
        let decision =
            classify_with_decision(&config, "hello").expect("should match simple greeting");
        assert_eq!(
            decision.tool_profile,
            Some(ToolProfile::Named(ToolProfileName::Minimal))
        );

        let decision =
            classify_with_decision(&config, "what time is it?").expect("should match time query");
        assert_eq!(
            decision.tool_profile,
            Some(ToolProfile::Named(ToolProfileName::Minimal))
        );
    }

    #[test]
    fn default_classification_rules_do_not_restrict_complex_queries() {
        let config = QueryClassificationConfig {
            enabled: true,
            rules: default_tool_classification_rules().to_vec(),
        };
        // Long complex queries match "moderate" hint but have no tool_profile override
        let decision = classify_with_decision(
            &config,
            "refactor the authentication module to use JWT tokens and add comprehensive test coverage",
        );
        assert!(decision.is_some());
        let d = decision.unwrap();
        assert_eq!(d.hint, "moderate");
        assert_eq!(d.tool_profile, None);
    }

    #[test]
    fn moderate_rule_matches_long_explain_query() {
        let config = QueryClassificationConfig {
            enabled: true,
            rules: default_tool_classification_rules().to_vec(),
        };
        let decision = classify_with_decision(
            &config,
            "explain how async/await works in Rust compared to goroutines",
        )
        .expect("should match moderate rule");
        assert_eq!(decision.hint, "moderate");
        assert_eq!(decision.tool_profile, None);
    }

    #[test]
    fn moderate_rule_rejects_short_queries() {
        let config = QueryClassificationConfig {
            enabled: true,
            rules: default_tool_classification_rules().to_vec(),
        };
        // "how to open a file" is 18 chars, below min_length 50
        let decision = classify_with_decision(&config, "how to open a file");
        let is_moderate = decision.as_ref().map(|d| d.hint.as_str()) == Some("moderate");
        assert!(!is_moderate, "Short query should not match 'moderate' rule");
    }

    #[test]
    fn skill_rule_beats_moderate_on_priority() {
        let config = QueryClassificationConfig {
            enabled: true,
            rules: default_tool_classification_rules().to_vec(),
        };
        let decision = classify_with_decision(
            &config,
            "run skill to explain something in detail for me please",
        )
        .expect("should match skill rule");
        assert_eq!(decision.hint, "skill");
    }
}
