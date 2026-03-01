# Dynamic Prompt-Relevant Tool and Skill Filtering

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Dynamically select which tools and skills appear in each prompt based on the current user message, reducing token waste from ~8-12k to ~1-3k for simple queries while preserving full capability when needed.

**Architecture:** Extend the existing `QueryClassificationConfig` classifier (keyword/pattern rules) to output a `ToolProfile` alongside the model hint. Add a `ToolSelector` trait with a rule-based default implementation that scores tool relevance per-message. Skills use compact mode by default with a new `skill_lookup` tool for on-demand loading. No embedding model, no second LLM call — pure config-driven rules evaluated in <1ms.

**Tech Stack:** Rust, serde, existing `ClassificationRule` infrastructure, existing `ToolProfile` and `SkillsPromptInjectionMode` enums.

---

## Current State (What PR #14 Built)

PR #14 (commit `0347a03f`) added:
- `ToolProfile` enum: `Full`, `Minimal`, `SkillRunner`, `Custom(Vec<String>)` in `src/config/schema.rs:730`
- `tool_profile` field on `AgentConfig` — **static**, set once in config
- `max_tool_calls_per_turn` — per-turn call budget with stop-message injection
- Profile filtering in `run_tool_call_loop` via `allowed_tools` parameter (`loop_.rs:800`)
- Profile filtering in system prompt tool descriptions (`loop_.rs:2040`)

**What PR #14 explicitly deferred:**
- Dynamic per-turn tool selection
- Skill routing / collision avoidance
- Compact mode activation for skills

The static profile works but requires the user to pick one profile for ALL messages. A "what time is it?" and "refactor my codebase" both see the same tools.

## Design: Three Layers

### Layer 1: Message-Aware Tool Profile Selection (config-driven, zero ML)

Extend `ClassificationRule` to optionally output a `ToolProfile`. The existing classifier already evaluates keyword/pattern rules per-message for model routing — we piggyback tool routing onto the same mechanism.

```
User: "what time is it?"
  -> ClassificationRule matches keyword "time", max_length=30
  -> hint: "fast", tool_profile: "minimal"
  -> Model sees 8 tools instead of 33

User: "refactor the auth module"
  -> ClassificationRule matches keyword "refactor", min_length=15
  -> hint: "code", tool_profile: "full"
  -> Model sees all 33 tools

User: "greet me" (skill invocation)
  -> ClassificationRule matches keyword "greet"
  -> hint: "fast", tool_profile: "skill_runner"
  -> Model sees 3 tools
```

This reuses the classifier that's already wired into `AgentOrchestrator::resolve_model` and `src/agent/loop_.rs:run()`. The `tool_profile` field on `ClassificationRule` is `Option<ToolProfile>` — when `None`, falls back to the static `config.agent.tool_profile`.

### Layer 2: Compact Skills with On-Demand Loading

The `SkillsPromptInjectionMode::Compact` enum variant already exists but is opt-in. We make it the default for `skill_runner` and `minimal` profiles, and add a lightweight `skill_lookup` tool that loads a single skill's full instructions on demand.

```
Compact mode (already implemented in skills_to_prompt_with_mode):
  - Only inlines skill name + description + file location
  - ~50 tokens per skill vs ~500 tokens per skill in Full mode
  - 10 skills: ~500 tokens compact vs ~5000 tokens full

skill_lookup tool (new):
  - Input: skill_name (string)
  - Output: full skill instructions + tool metadata
  - Model calls this when it identifies which skill to run
  - Eliminates skill collision: model reads only the skill it chose
```

### Layer 3: Tool Relevance Scoring (keyword-based, no ML)

For messages that don't match any classification rule, score each tool against the message using keyword overlap. Tools with zero relevance are excluded. This is the fallback for unclassified messages.

```rust
trait ToolSelector: Send + Sync {
    fn select_tools(
        &self,
        message: &str,
        all_tools: &[&str],
        config_profile: &ToolProfile,
    ) -> Vec<String>;
}
```

Default implementation: each tool gets a set of relevance keywords (derived from tool name + description). Score = number of keyword matches. Tools scoring 0 are excluded unless they're in a "core" set (shell, file_read are always included). This is evaluated per-message in <1ms.

## Approach Evaluation

| Approach | Complexity | Token Savings | Latency | Risk |
|----------|-----------|---------------|---------|------|
| Layer 1: Classification rules → tool_profile | Low | High for matching messages | <1ms | Low — extends existing infra |
| Layer 2: Compact skills + skill_lookup tool | Medium | ~4-5k tokens when skills loaded | <1ms + 1 tool call | Medium — new tool, behavior change |
| Layer 3: Keyword relevance scoring | Medium | Moderate for unclassified messages | <1ms | Medium — heuristic, may exclude needed tools |

**Recommendation:** Implement Layer 1 first (highest value/effort ratio), Layer 2 second (addresses skill collision), Layer 3 as stretch goal.

---

## Task 1: Add `tool_profile` Field to `ClassificationRule`

**Files:**
- Modify: `src/config/schema.rs` (ClassificationRule struct, ~line 3753)
- Test: `src/agent/classifier.rs` (existing test module)

**Step 1: Write the failing test**

In `src/agent/classifier.rs`, add a test that verifies classification returns a tool profile:

```rust
#[test]
fn classify_returns_tool_profile_when_rule_specifies_one() {
    let config = make_config(
        true,
        vec![ClassificationRule {
            hint: "fast".into(),
            keywords: vec!["time".into()],
            tool_profile: Some(ToolProfile::Named(ToolProfileName::Minimal)),
            ..Default::default()
        }],
    );
    let decision = classify_with_decision(&config, "what time is it?")
        .expect("should match");
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
    let decision = classify_with_decision(&config, "hello there")
        .expect("should match");
    assert_eq!(decision.tool_profile, None);
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --release -p zeroclaw classify_returns_tool_profile -- --nocapture`
Expected: FAIL — `ClassificationRule` has no `tool_profile` field, `ClassificationDecision` has no `tool_profile` field.

**Step 3: Add `tool_profile` to `ClassificationRule` and `ClassificationDecision`**

In `src/config/schema.rs`, add to `ClassificationRule`:

```rust
/// Optional tool profile override for this rule. When set, messages matching
/// this rule use this profile instead of `agent.tool_profile`.
#[serde(default)]
pub tool_profile: Option<ToolProfile>,
```

In `src/agent/classifier.rs`, add to `ClassificationDecision`:

```rust
pub struct ClassificationDecision {
    pub hint: String,
    pub priority: i32,
    pub tool_profile: Option<ToolProfile>,
}
```

Update the `classify_with_decision` function to populate the new field:

```rust
return Some(ClassificationDecision {
    hint: rule.hint.clone(),
    priority: rule.priority,
    tool_profile: rule.tool_profile.clone(),
});
```

**Step 4: Run test to verify it passes**

Run: `cargo test --release -p zeroclaw classify_returns_tool_profile -- --nocapture`
Expected: PASS

**Step 5: Commit**

```powershell
git add src/config/schema.rs src/agent/classifier.rs
git commit -m "feat(classifier): add tool_profile field to ClassificationRule and ClassificationDecision"
```

---

## Task 2: Wire Classification Tool Profile into Agent Loop

**Files:**
- Modify: `src/agent/loop_.rs` (~line 2040, where `resolved_tool_profile` is computed)
- Modify: `src/agent/agent.rs` (where `resolve_model` calls the classifier)
- Test: `src/agent/loop_.rs` (existing test module)

**Step 1: Write the failing test**

In `src/agent/loop_.rs` tests, add a test that verifies when a classification decision includes a tool_profile, it overrides the static config profile. (This may need to be an integration-style test or a unit test on a helper function.)

Since `run_tool_call_loop` is hard to unit test directly, we'll extract the profile resolution logic into a testable function:

```rust
#[test]
fn resolve_effective_tool_profile_uses_classification_override() {
    let static_profile = ToolProfile::Named(ToolProfileName::Full);
    let classification_override = Some(ToolProfile::Named(ToolProfileName::Minimal));
    let effective = resolve_effective_tool_profile(&static_profile, classification_override.as_ref());
    assert_eq!(effective, ToolProfile::Named(ToolProfileName::Minimal));
}

#[test]
fn resolve_effective_tool_profile_falls_back_to_static_when_no_override() {
    let static_profile = ToolProfile::Named(ToolProfileName::Minimal);
    let effective = resolve_effective_tool_profile(&static_profile, None);
    assert_eq!(effective, ToolProfile::Named(ToolProfileName::Minimal));
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --release -p zeroclaw resolve_effective_tool_profile -- --nocapture`
Expected: FAIL — function doesn't exist yet.

**Step 3: Implement `resolve_effective_tool_profile` and wire it in**

In `src/agent/loop_.rs`, add:

```rust
fn resolve_effective_tool_profile(
    static_profile: &ToolProfile,
    classification_override: Option<&ToolProfile>,
) -> ToolProfile {
    classification_override
        .cloned()
        .unwrap_or_else(|| static_profile.clone())
}
```

In the `run()` function (~line 2040), change:

```rust
// Before:
let resolved_tool_profile = config.agent.tool_profile.resolve();

// After:
let classification_tool_profile = /* get from classifier decision */;
let effective_profile = resolve_effective_tool_profile(
    &config.agent.tool_profile,
    classification_tool_profile.as_ref(),
);
let resolved_tool_profile = effective_profile.resolve();
```

The classifier decision needs to be threaded from `AgentOrchestrator::resolve_model` (in `agent.rs`) into the `run()` function. The cleanest path: `resolve_model` already returns a model name string. Change it to return a `RouteDecision` struct that includes both model and optional tool profile.

In `src/agent/agent.rs`, add:

```rust
pub(crate) struct RouteDecision {
    pub model: String,
    pub tool_profile: Option<ToolProfile>,
}
```

Update `resolve_model` to return `RouteDecision` and populate `tool_profile` from the classifier decision.

**Step 4: Run tests to verify they pass**

Run: `cargo test --release -p zeroclaw resolve_effective_tool_profile -- --nocapture`
Expected: PASS

Run: `cargo test --release` (full suite)
Expected: PASS — backward compatible because `tool_profile` defaults to `None` on all existing rules.

**Step 5: Commit**

```powershell
git add src/agent/loop_.rs src/agent/agent.rs
git commit -m "feat(agent): wire classification tool_profile into agent loop for dynamic per-message filtering"
```

---

## Task 3: Add Default Classification Rules for Common Patterns

**Files:**
- Modify: `src/config/schema.rs` (add default rules factory function)
- Create: `docs/reference/tool-filtering.md` (document the feature)
- Test: `src/agent/classifier.rs`

**Step 1: Write the failing test**

```rust
#[test]
fn default_classification_rules_route_simple_queries_to_minimal() {
    let config = QueryClassificationConfig {
        enabled: true,
        rules: default_tool_classification_rules(),
    };
    // Simple greeting → minimal tools
    let decision = classify_with_decision(&config, "hello")
        .expect("should match simple greeting");
    assert_eq!(decision.tool_profile, Some(ToolProfile::Named(ToolProfileName::Minimal)));

    // Time query → minimal tools
    let decision = classify_with_decision(&config, "what time is it?")
        .expect("should match time query");
    assert_eq!(decision.tool_profile, Some(ToolProfile::Named(ToolProfileName::Minimal)));
}

#[test]
fn default_classification_rules_do_not_restrict_complex_queries() {
    let config = QueryClassificationConfig {
        enabled: true,
        rules: default_tool_classification_rules(),
    };
    // Complex request → no match (falls through to static profile)
    assert!(classify_with_decision(&config, "refactor the authentication module to use JWT tokens and add comprehensive test coverage").is_none());
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --release -p zeroclaw default_classification_rules -- --nocapture`
Expected: FAIL — `default_tool_classification_rules` doesn't exist.

**Step 3: Implement default rules**

In `src/agent/classifier.rs` (or a new `src/agent/default_rules.rs`), add:

```rust
pub fn default_tool_classification_rules() -> Vec<ClassificationRule> {
    vec![
        // Short, simple queries (< 50 chars) with greeting/time/date keywords → minimal tools
        ClassificationRule {
            hint: "simple".into(),
            keywords: vec![
                "hello".into(), "hi".into(), "hey".into(),
                "time".into(), "date".into(), "weather".into(),
                "thanks".into(), "thank you".into(),
            ],
            max_length: Some(50),
            priority: 1,
            tool_profile: Some(ToolProfile::Named(ToolProfileName::Minimal)),
            ..Default::default()
        },
        // Skill trigger patterns → skill_runner profile
        ClassificationRule {
            hint: "skill".into(),
            keywords: vec![
                "greet me".into(),
                "check git status".into(),
                "create a skill".into(),
                "run skill".into(),
            ],
            priority: 5,
            tool_profile: Some(ToolProfile::Named(ToolProfileName::SkillRunner)),
            ..Default::default()
        },
    ]
}
```

These are conservative defaults. Users extend via config. The `hint` field can also route to cheaper/faster models.

**Step 4: Run tests to verify they pass**

Run: `cargo test --release -p zeroclaw default_classification_rules -- --nocapture`
Expected: PASS

**Step 5: Commit**

```powershell
git add src/agent/classifier.rs src/config/schema.rs
git commit -m "feat(classifier): add default tool classification rules for common query patterns"
```

---

## Task 4: Add `skill_lookup` Tool for On-Demand Skill Loading

**Files:**
- Create: `src/tools/skill_lookup.rs`
- Modify: `src/tools/mod.rs` (register the tool)
- Test: `src/tools/skill_lookup.rs`

**Step 1: Write the failing test**

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn skill_lookup_returns_full_instructions_for_known_skill() {
        let skills = vec![crate::skills::Skill {
            name: "greeting".into(),
            description: "Greet the user".into(),
            version: "1.0".into(),
            author: None,
            tags: vec![],
            tools: vec![],
            prompts: vec!["Say hello warmly.".into()],
            location: None,
        }];
        let tool = SkillLookupTool::new(skills);
        let result = tool
            .execute(serde_json::json!({"skill_name": "greeting"}), None)
            .await
            .unwrap();
        assert!(result.output.contains("Say hello warmly"));
    }

    #[tokio::test]
    async fn skill_lookup_returns_error_for_unknown_skill() {
        let tool = SkillLookupTool::new(vec![]);
        let result = tool
            .execute(serde_json::json!({"skill_name": "nonexistent"}), None)
            .await
            .unwrap();
        assert!(result.output.contains("not found"));
    }
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --release -p zeroclaw skill_lookup -- --nocapture`
Expected: FAIL — module doesn't exist.

**Step 3: Implement `SkillLookupTool`**

Create `src/tools/skill_lookup.rs`:

```rust
use crate::skills::Skill;
use crate::tools::{Tool, ToolResult, ToolSpec};
use async_trait::async_trait;
use serde_json::Value;
use std::sync::Arc;

pub struct SkillLookupTool {
    skills: Arc<Vec<Skill>>,
}

impl SkillLookupTool {
    pub fn new(skills: Vec<Skill>) -> Self {
        Self {
            skills: Arc::new(skills),
        }
    }
}

#[async_trait]
impl Tool for SkillLookupTool {
    fn name(&self) -> &str {
        "skill_lookup"
    }

    fn description(&self) -> &str {
        "Look up full instructions for a skill by name. Use when you need to execute a skill and are in compact mode."
    }

    fn parameters_schema(&self) -> &str {
        r#"{"type":"object","properties":{"skill_name":{"type":"string","description":"Name of the skill to look up"}},"required":["skill_name"]}"#
    }

    fn spec(&self) -> ToolSpec {
        ToolSpec {
            name: self.name().to_string(),
            description: self.description().to_string(),
            parameters: serde_json::from_str(self.parameters_schema()).unwrap_or_default(),
        }
    }

    async fn execute(
        &self,
        args: Value,
        _workspace_dir: Option<&std::path::Path>,
    ) -> anyhow::Result<ToolResult> {
        let skill_name = args
            .get("skill_name")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let skill = self.skills.iter().find(|s| s.name == skill_name);

        match skill {
            Some(s) => {
                let mut output = format!("# Skill: {}\n\n", s.name);
                output.push_str(&format!("Description: {}\n\n", s.description));
                if !s.prompts.is_empty() {
                    output.push_str("## Instructions\n\n");
                    for (i, instruction) in s.prompts.iter().enumerate() {
                        output.push_str(&format!("{}. {}\n", i + 1, instruction));
                    }
                }
                if !s.tools.is_empty() {
                    output.push_str("\n## Skill Tools\n\n");
                    for tool in &s.tools {
                        output.push_str(&format!("- **{}** ({}): {}\n", tool.name, tool.kind, tool.description));
                    }
                }
                Ok(ToolResult {
                    output,
                    is_error: false,
                })
            }
            None => {
                let available: Vec<&str> = self.skills.iter().map(|s| s.name.as_str()).collect();
                Ok(ToolResult {
                    output: format!(
                        "Skill '{}' not found. Available skills: {}",
                        skill_name,
                        available.join(", ")
                    ),
                    is_error: true,
                })
            }
        }
    }
}
```

Register in `src/tools/mod.rs` — add `pub mod skill_lookup;` and include in the tool registration when compact mode is active.

**Step 4: Run tests to verify they pass**

Run: `cargo test --release -p zeroclaw skill_lookup -- --nocapture`
Expected: PASS

**Step 5: Commit**

```powershell
git add src/tools/skill_lookup.rs src/tools/mod.rs
git commit -m "feat(tools): add skill_lookup tool for on-demand skill loading in compact mode"
```

---

## Task 5: Auto-Activate Compact Mode Based on Tool Profile

**Files:**
- Modify: `src/agent/loop_.rs` (~line 2060, where `skills_prompt_mode` is used)
- Test: `src/agent/loop_.rs`

**Step 1: Write the failing test**

```rust
#[test]
fn skill_runner_profile_forces_compact_skills_mode() {
    let profile = ToolProfile::Named(ToolProfileName::SkillRunner);
    let config_mode = SkillsPromptInjectionMode::Full;
    let effective = resolve_effective_skills_mode(&profile, config_mode);
    assert_eq!(effective, SkillsPromptInjectionMode::Compact);
}

#[test]
fn full_profile_preserves_configured_skills_mode() {
    let profile = ToolProfile::Named(ToolProfileName::Full);
    let config_mode = SkillsPromptInjectionMode::Full;
    let effective = resolve_effective_skills_mode(&profile, config_mode);
    assert_eq!(effective, SkillsPromptInjectionMode::Full);
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --release -p zeroclaw skill_runner_profile_forces -- --nocapture`
Expected: FAIL — function doesn't exist.

**Step 3: Implement `resolve_effective_skills_mode`**

```rust
fn resolve_effective_skills_mode(
    profile: &ToolProfile,
    config_mode: SkillsPromptInjectionMode,
) -> SkillsPromptInjectionMode {
    match profile {
        ToolProfile::Named(ToolProfileName::SkillRunner | ToolProfileName::Minimal) => {
            SkillsPromptInjectionMode::Compact
        }
        _ => config_mode,
    }
}
```

Wire this into the system prompt construction so that when the effective profile is `SkillRunner` or `Minimal`, skills automatically use compact mode regardless of config.

Also ensure the `skill_lookup` tool is added to the tools registry when compact mode is active, so the model can still load skill details on demand.

**Step 4: Run tests**

Run: `cargo test --release -p zeroclaw skill_runner_profile_forces -- --nocapture`
Expected: PASS

**Step 5: Commit**

```powershell
git add src/agent/loop_.rs
git commit -m "feat(agent): auto-activate compact skills mode for minimal/skill_runner profiles"
```

---

## Task 6: Tool Relevance Scoring (Stretch Goal)

**Files:**
- Create: `src/agent/tool_selector.rs`
- Modify: `src/agent/mod.rs`
- Test: `src/agent/tool_selector.rs`

**Step 1: Write the failing test**

```rust
#[test]
fn keyword_scorer_excludes_irrelevant_tools() {
    let scorer = KeywordToolSelector::default();
    let all_tools = &[
        "shell", "file_read", "file_write", "file_edit",
        "memory_store", "memory_recall",
        "browser_open", "web_search", "web_fetch",
        "http_request", "gpio_read", "gpio_write",
    ];
    let selected = scorer.select_tools(
        "what time is it?",
        all_tools,
        &ToolProfile::Named(ToolProfileName::Full),
    );
    // shell is always included (core tool)
    assert!(selected.contains(&"shell".to_string()));
    // browser/gpio/http should NOT be included for a time query
    assert!(!selected.contains(&"browser_open".to_string()));
    assert!(!selected.contains(&"gpio_read".to_string()));
}

#[test]
fn keyword_scorer_includes_file_tools_for_code_query() {
    let scorer = KeywordToolSelector::default();
    let all_tools = &["shell", "file_read", "file_write", "file_edit", "browser_open"];
    let selected = scorer.select_tools(
        "read the main.rs file and fix the bug",
        all_tools,
        &ToolProfile::Named(ToolProfileName::Full),
    );
    assert!(selected.contains(&"file_read".to_string()));
    assert!(selected.contains(&"file_edit".to_string()));
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test --release -p zeroclaw keyword_scorer -- --nocapture`
Expected: FAIL — module doesn't exist.

**Step 3: Implement `KeywordToolSelector`**

```rust
use crate::config::ToolProfile;
use std::collections::HashMap;

pub trait ToolSelector: Send + Sync {
    fn select_tools(
        &self,
        message: &str,
        all_tools: &[&str],
        config_profile: &ToolProfile,
    ) -> Vec<String>;
}

const CORE_TOOLS: &[&str] = &["shell", "file_read"];

pub struct KeywordToolSelector {
    tool_keywords: HashMap<String, Vec<String>>,
}

impl Default for KeywordToolSelector {
    fn default() -> Self {
        let mut map = HashMap::new();
        map.insert("file_read".into(), vec!["file", "read", "cat", "show", "content", "code", "source"].into_iter().map(String::from).collect());
        map.insert("file_write".into(), vec!["write", "create", "save", "new file"].into_iter().map(String::from).collect());
        map.insert("file_edit".into(), vec!["edit", "fix", "change", "modify", "update", "refactor", "bug"].into_iter().map(String::from).collect());
        map.insert("memory_store".into(), vec!["remember", "save", "store", "note"].into_iter().map(String::from).collect());
        map.insert("memory_recall".into(), vec!["recall", "remember", "what did", "history", "previous"].into_iter().map(String::from).collect());
        map.insert("browser_open".into(), vec!["browser", "webpage", "website", "url", "open page"].into_iter().map(String::from).collect());
        map.insert("web_search".into(), vec!["search", "google", "look up", "find online"].into_iter().map(String::from).collect());
        map.insert("web_fetch".into(), vec!["fetch", "download", "curl", "http get"].into_iter().map(String::from).collect());
        map.insert("http_request".into(), vec!["api", "request", "post", "endpoint", "rest"].into_iter().map(String::from).collect());
        map.insert("glob_search".into(), vec!["find file", "glob", "search files", "locate"].into_iter().map(String::from).collect());
        map.insert("content_search".into(), vec!["grep", "search content", "find in files", "pattern"].into_iter().map(String::from).collect());
        map.insert("gpio_read".into(), vec!["gpio", "pin", "hardware", "sensor", "led", "arduino", "nucleo"].into_iter().map(String::from).collect());
        map.insert("gpio_write".into(), vec!["gpio", "pin", "hardware", "led", "blink", "arduino", "nucleo"].into_iter().map(String::from).collect());
        Self { tool_keywords: map }
    }
}

impl ToolSelector for KeywordToolSelector {
    fn select_tools(
        &self,
        message: &str,
        all_tools: &[&str],
        config_profile: &ToolProfile,
    ) -> Vec<String> {
        // If profile is already restrictive, respect it
        if let Some(resolved) = config_profile.resolve() {
            return resolved;
        }

        let lower = message.to_lowercase();
        let mut selected: Vec<String> = Vec::new();

        // Always include core tools
        for core in CORE_TOOLS {
            if all_tools.contains(core) {
                selected.push(core.to_string());
            }
        }

        // Score each tool
        for tool_name in all_tools {
            if selected.contains(&tool_name.to_string()) {
                continue;
            }
            if let Some(keywords) = self.tool_keywords.get(*tool_name) {
                let score = keywords.iter().filter(|kw| lower.contains(kw.as_str())).count();
                if score > 0 {
                    selected.push(tool_name.to_string());
                }
            } else {
                // Unknown tool (MCP, plugin, etc.) — include by default
                selected.push(tool_name.to_string());
            }
        }

        // If fewer than 5 tools selected and message is complex (>100 chars),
        // include all tools as safety fallback
        if selected.len() < 5 && message.len() > 100 {
            return all_tools.iter().map(|s| s.to_string()).collect();
        }

        selected
    }
}
```

**Step 4: Run tests**

Run: `cargo test --release -p zeroclaw keyword_scorer -- --nocapture`
Expected: PASS

**Step 5: Commit**

```powershell
git add src/agent/tool_selector.rs src/agent/mod.rs
git commit -m "feat(agent): add keyword-based ToolSelector for dynamic tool relevance scoring"
```

---

## Task 7: Integration Wiring and Config Defaults

**Files:**
- Modify: `src/agent/loop_.rs` (wire ToolSelector into the run function)
- Modify: `src/config/schema.rs` (add `dynamic_tool_filtering` config flag)
- Test: integration test

**Step 1: Write the failing test**

```rust
#[test]
fn dynamic_tool_filtering_disabled_by_default() {
    let config: AgentConfig = Default::default();
    assert!(!config.dynamic_tool_filtering);
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — field doesn't exist.

**Step 3: Add config flag and wire integration**

In `src/config/schema.rs`, add to `AgentConfig`:

```rust
/// Enable dynamic per-message tool filtering based on keyword relevance scoring.
/// When enabled and no classification rule matches, tools are scored against the
/// user message and irrelevant tools are excluded. Default: `false`.
#[serde(default)]
pub dynamic_tool_filtering: bool,
```

In `src/agent/loop_.rs`, the `run()` function resolution order becomes:

```
1. Check ClassificationRule for tool_profile override → if found, use it
2. If dynamic_tool_filtering enabled and no classification match → run ToolSelector
3. Fall back to static config.agent.tool_profile
```

**Step 4: Run full test suite**

Run: `cargo test --release`
Expected: PASS — new feature is off by default.

**Step 5: Commit**

```powershell
git add src/config/schema.rs src/agent/loop_.rs
git commit -m "feat(agent): integrate dynamic tool filtering with classification rules and keyword scoring"
```

---

## Task 8: Backward Compatibility and Validation

**Files:**
- Modify: existing test files
- No new files

**Step 1: Write backward compatibility tests**

```rust
#[test]
fn config_without_tool_classification_rules_works_unchanged() {
    let toml = r#"
        [agent]
        tool_profile = "full"
    "#;
    let config: Config = toml::from_str(toml).unwrap();
    assert!(config.query_classification.rules.is_empty());
    assert!(!config.agent.dynamic_tool_filtering);
    // Static profile is used, no dynamic filtering
}

#[test]
fn existing_tool_profile_config_still_works() {
    let toml = r#"
        [agent]
        tool_profile = "skill_runner"
        max_tool_calls_per_turn = 3
    "#;
    let config: Config = toml::from_str(toml).unwrap();
    assert_eq!(
        config.agent.tool_profile,
        ToolProfile::Named(ToolProfileName::SkillRunner)
    );
    assert_eq!(config.agent.max_tool_calls_per_turn, 3);
}
```

**Step 2: Run tests**

Run: `cargo test --release`
Expected: PASS

**Step 3: Run full validation**

```powershell
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test --release
```

**Step 4: Commit**

```powershell
git add -A
git commit -m "test: add backward compatibility tests for dynamic tool filtering"
```

---

## Token Budget Impact (Expected)

| Scenario | Before (static full) | After (dynamic) | Savings |
|----------|---------------------|-----------------|---------|
| "what time is it?" | ~8-12k tokens (33 tools + all skills) | ~1-2k tokens (8 tools, compact skills) | 75-85% |
| "greet me" (skill) | ~8-12k tokens | ~0.5-1k tokens (3 tools, compact skills) | 90%+ |
| "refactor auth module" | ~8-12k tokens | ~8-12k tokens (full profile, no change) | 0% |
| "read main.rs and fix bug" | ~8-12k tokens | ~3-5k tokens (file tools + shell + compact skills) | 50-60% |

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Classification rules too aggressive — exclude needed tools | Medium | High — silent failure | Conservative defaults (only filter short/simple queries). `Full` profile fallback for unclassified messages. |
| `skill_lookup` tool adds overhead — model calls it unnecessarily | Low | Low — one extra tool call | Only registered in compact mode. Clear description says "use when in compact mode". |
| Keyword scorer too naive — misses relevant tools | Medium | Medium — degraded experience | Off by default (`dynamic_tool_filtering = false`). Core tools always included. Fallback to full set for complex messages. |
| Config schema change breaks existing configs | Low | High | All new fields have `#[serde(default)]`. Existing configs work unchanged. |

## Rollback

Each task is a separate commit. Rollback any task independently:
- Task 1-3: Revert classification rule changes → falls back to static profile
- Task 4-5: Revert skill_lookup + compact auto-activation → skills stay in full mode
- Task 6-7: Revert keyword scorer → no dynamic scoring, classification rules still work
- Full rollback: `git revert <commit-range>` → exact pre-PR behavior

## Non-Goals (YAGNI)

- Embedding-based tool relevance (requires embedding model + vector DB lookup per message)
- LLM-based tool selection (second API call per message — defeats the purpose)
- Tool schema compression (prompt engineering, not code change)
- Per-iteration tool switching within a single turn (Vercel prepareStep — requires loop refactor)
- Automatic learning from tool usage patterns (requires telemetry pipeline)
