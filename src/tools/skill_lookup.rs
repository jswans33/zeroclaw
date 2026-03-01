use super::traits::{Tool, ToolResult};
use crate::skills::Skill;
use async_trait::async_trait;
use serde_json::json;
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

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "skill_name": {
                    "type": "string",
                    "description": "Name of the skill to look up"
                }
            },
            "required": ["skill_name"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let skill_name = args
            .get("skill_name")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default();

        if skill_name.is_empty() {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some("skill_name parameter is required".into()),
            });
        }

        match self.skills.iter().find(|s| s.name == skill_name) {
            Some(skill) => {
                let mut output = format!(
                    "Skill: {}\nVersion: {}\nDescription: {}",
                    skill.name, skill.version, skill.description
                );

                if let Some(author) = &skill.author {
                    output.push_str(&format!("\nAuthor: {author}"));
                }

                if !skill.tags.is_empty() {
                    output.push_str(&format!("\nTags: {}", skill.tags.join(", ")));
                }

                if !skill.tools.is_empty() {
                    output.push_str("\n\nTools:");
                    for tool in &skill.tools {
                        output.push_str(&format!(
                            "\n  - {} ({}): {}",
                            tool.name, tool.kind, tool.description
                        ));
                    }
                }

                if !skill.prompts.is_empty() {
                    output.push_str("\n\nInstructions:");
                    for prompt in &skill.prompts {
                        output.push_str(&format!("\n{prompt}"));
                    }
                }

                if let Some(location) = &skill.location {
                    output.push_str(&format!("\nLocation: {}", location.display()));
                }

                Ok(ToolResult {
                    success: true,
                    output,
                    error: None,
                })
            }
            None => {
                let available: Vec<&str> = self.skills.iter().map(|s| s.name.as_str()).collect();
                let msg = if available.is_empty() {
                    format!("Skill '{skill_name}' not found. No skills are loaded.")
                } else {
                    format!(
                        "Skill '{skill_name}' not found. Available skills: {}",
                        available.join(", ")
                    )
                };
                Ok(ToolResult {
                    success: false,
                    output: String::new(),
                    error: Some(msg),
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skills::SkillTool;
    use std::collections::HashMap;

    fn test_skill() -> Skill {
        Skill {
            name: "weather_lookup".into(),
            description: "Look up current weather for a city".into(),
            version: "1.0.0".into(),
            author: Some("zeroclaw_user".into()),
            tags: vec!["weather".into(), "api".into()],
            tools: vec![SkillTool {
                name: "get_weather".into(),
                description: "Fetch weather data".into(),
                kind: "http".into(),
                command: "https://api.example.com/weather".into(),
                args: HashMap::default(),
            }],
            prompts: vec![
                "Use the get_weather tool to fetch weather data.".into(),
                "Return temperature in Celsius.".into(),
            ],
            location: None,
        }
    }

    #[tokio::test]
    async fn skill_lookup_returns_full_instructions_for_known_skill() {
        let tool = SkillLookupTool::new(vec![test_skill()]);
        let result = tool
            .execute(json!({"skill_name": "weather_lookup"}))
            .await
            .unwrap();

        assert!(result.success);
        assert!(result.error.is_none());
        assert!(result.output.contains("weather_lookup"));
        assert!(result.output.contains("1.0.0"));
        assert!(result.output.contains("Look up current weather for a city"));
        assert!(result.output.contains("zeroclaw_user"));
        assert!(result.output.contains("weather, api"));
        assert!(result.output.contains("get_weather"));
        assert!(result.output.contains("Fetch weather data"));
        assert!(result.output.contains("Use the get_weather tool"));
        assert!(result.output.contains("Return temperature in Celsius"));
    }

    #[tokio::test]
    async fn skill_lookup_returns_error_for_unknown_skill() {
        let tool = SkillLookupTool::new(vec![test_skill()]);
        let result = tool
            .execute(json!({"skill_name": "nonexistent"}))
            .await
            .unwrap();

        assert!(!result.success);
        assert!(result.output.is_empty());
        let err = result.error.unwrap();
        assert!(err.contains("nonexistent"));
        assert!(err.contains("not found"));
    }

    #[tokio::test]
    async fn skill_lookup_returns_error_for_empty_skill_name() {
        let tool = SkillLookupTool::new(vec![test_skill()]);
        let result = tool.execute(json!({"skill_name": ""})).await.unwrap();

        assert!(!result.success);
        assert!(result.output.is_empty());
        let err = result.error.unwrap();
        assert!(err.contains("required"));
    }

    #[tokio::test]
    async fn skill_lookup_returns_error_for_missing_skill_name_param() {
        let tool = SkillLookupTool::new(vec![test_skill()]);
        let result = tool.execute(json!({})).await.unwrap();

        assert!(!result.success);
        assert!(result.output.is_empty());
        let err = result.error.unwrap();
        assert!(err.contains("required"));
    }

    #[tokio::test]
    async fn skill_lookup_with_empty_skills_list_reports_no_skills_loaded() {
        let tool = SkillLookupTool::new(vec![]);
        let result = tool
            .execute(json!({"skill_name": "anything"}))
            .await
            .unwrap();

        assert!(!result.success);
        let err = result.error.unwrap();
        assert!(err.contains("not found"));
        assert!(err.contains("No skills are loaded"));
    }

    #[tokio::test]
    async fn skill_lookup_lists_available_skills_on_miss() {
        let mut skill2 = test_skill();
        skill2.name = "code_review".into();

        let tool = SkillLookupTool::new(vec![test_skill(), skill2]);
        let result = tool
            .execute(json!({"skill_name": "missing_skill"}))
            .await
            .unwrap();

        assert!(!result.success);
        let err = result.error.unwrap();
        assert!(err.contains("weather_lookup"));
        assert!(err.contains("code_review"));
    }
}
