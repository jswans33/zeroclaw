#[cfg(test)]
mod tests {
    use crate::skills::skills_dir;
    use std::path::Path;
    use tempfile::TempDir;

    #[cfg(unix)]
    #[tokio::test]
    async fn test_skills_symlink_unix_edge_cases() {
        use std::os::unix::fs::symlink;

        let tmp = TempDir::new().unwrap();
        let workspace_dir = tmp.path().join("workspace");
        tokio::fs::create_dir_all(&workspace_dir).await.unwrap();

        let skills_path = skills_dir(&workspace_dir);
        tokio::fs::create_dir_all(&skills_path).await.unwrap();

        // Test case 1: Valid symlink creation
        let source_dir = tmp.path().join("source_skill");
        tokio::fs::create_dir_all(&source_dir).await.unwrap();
        tokio::fs::write(source_dir.join("SKILL.md"), "# Test Skill\nContent")
            .await
            .unwrap();

        let dest_link = skills_path.join("linked_skill");
        let result = symlink(&source_dir, &dest_link);
        assert!(result.is_ok(), "Symlink creation should succeed");

        assert!(dest_link.exists());
        assert!(dest_link.is_symlink());

        let content = tokio::fs::read_to_string(dest_link.join("SKILL.md")).await;
        assert!(content.is_ok());
        assert!(content.unwrap().contains("Test Skill"));

        // Test case 2: Symlink to non-existent target should fail gracefully
        let broken_link = skills_path.join("broken_skill");
        let non_existent = tmp.path().join("non_existent");
        let result = symlink(&non_existent, &broken_link);
        assert!(
            result.is_ok(),
            "Symlink creation should succeed even if target doesn't exist"
        );

        let content = tokio::fs::read_to_string(broken_link.join("SKILL.md")).await;
        assert!(content.is_err());

        // Test case 3: skills_dir function edge cases
        let workspace_with_trailing_slash = format!("{}/", workspace_dir.display());
        let path_from_str = skills_dir(Path::new(&workspace_with_trailing_slash));
        assert_eq!(path_from_str, skills_path);

        // Test case 4: Empty workspace directory
        let empty_workspace = tmp.path().join("empty");
        let empty_skills_path = skills_dir(&empty_workspace);
        assert_eq!(empty_skills_path, empty_workspace.join("skills"));
        assert!(!empty_skills_path.exists());
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn test_skills_symlink_windows() {
        use std::os::windows::fs::symlink_dir;

        let tmp = TempDir::new().unwrap();
        let workspace_dir = tmp.path().join("workspace");
        tokio::fs::create_dir_all(&workspace_dir).await.unwrap();

        let skills_path = skills_dir(&workspace_dir);
        tokio::fs::create_dir_all(&skills_path).await.unwrap();

        let source_dir = tmp.path().join("source_skill");
        tokio::fs::create_dir_all(&source_dir).await.unwrap();

        let dest_link = skills_path.join("linked_skill");

        let result = symlink_dir(&source_dir, &dest_link);
        if result.is_err() {
            assert!(!dest_link.exists());
        } else {
            let _ = tokio::fs::remove_dir(&dest_link).await;
        }

        // skills_dir function edge cases
        let workspace_with_trailing_slash = format!("{}\\", workspace_dir.display());
        let path_from_str = skills_dir(Path::new(&workspace_with_trailing_slash));
        assert_eq!(path_from_str, skills_path);

        let empty_workspace = tmp.path().join("empty");
        let empty_skills_path = skills_dir(&empty_workspace);
        assert_eq!(empty_skills_path, empty_workspace.join("skills"));
        assert!(!empty_skills_path.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn test_skills_symlink_permissions_and_safety() {
        use std::os::unix::fs::symlink;

        let tmp = TempDir::new().unwrap();
        let workspace_dir = tmp.path().join("workspace");
        tokio::fs::create_dir_all(&workspace_dir).await.unwrap();

        let skills_path = skills_dir(&workspace_dir);
        tokio::fs::create_dir_all(&skills_path).await.unwrap();

        let outside_dir = tmp.path().join("outside_skill");
        tokio::fs::create_dir_all(&outside_dir).await.unwrap();
        tokio::fs::write(outside_dir.join("SKILL.md"), "# Outside Skill\nContent")
            .await
            .unwrap();

        let dest_link = skills_path.join("outside_skill");
        let result = symlink(&outside_dir, &dest_link);
        assert!(
            result.is_ok(),
            "Should allow symlinking to directories outside workspace"
        );

        let content = tokio::fs::read_to_string(dest_link.join("SKILL.md")).await;
        assert!(content.is_ok());
        assert!(content.unwrap().contains("Outside Skill"));
    }
}
