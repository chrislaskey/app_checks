//! Separate pull request: a file in a named group must be the only kind of
//! change in the branch. Several files from the same group may change
//! together. Nothing else may change with them.
//!
//! This keeps the files that decide what gets checked, or who reviews, in
//! a pull request of their own, where the change is the whole story.
//!
//! The config lists the groups, one key per group, with a path pattern per
//! value: `groups.agents=AGENTS.md`, `groups.lint_config=.credo.exs`. A
//! pattern matches the whole path from the project root. `*` does not
//! cross a `/`, `**` does.
//!
//! The check is about the branch, so it reads what the branch changed
//! whatever its scope is. Every violation is about a file.

use globset::GlobSet;

use crate::check::{glob_set, Check, Config, State, Violation};

pub struct SeparatePr;

/// The check this file contributes. Every file in `src/checks/` exports one.
pub const CHECK: &dyn Check = &SeparatePr;

impl Check for SeparatePr {
    fn name(&self) -> &'static str {
        "separate_pr"
    }

    fn config_keys(&self) -> &'static [&'static str] {
        &["groups.*"]
    }

    fn prepare(&self, config: &Config) -> Result<(), String> {
        groups(config).map(|_| ())
    }

    fn run(&self, state: &State, config: &Config) -> Result<Vec<Violation>, String> {
        let groups = groups(config)?;

        // Where each changed path landed: the index of its group, or none.
        let placed: Vec<(&std::path::Path, Option<usize>)> = state
            .changed()
            .iter()
            .map(|file| {
                let path = file.path.as_path();
                (path, groups.iter().position(|(_, set)| set.is_match(path)))
            })
            .collect();

        // The first grouped path, in path order, is the one everything else
        // must be grouped with.
        let Some((anchor, Some(group))) = placed.iter().find(|(_, group)| group.is_some()) else {
            return Ok(Vec::new());
        };
        let group_name = &groups[*group].0;

        Ok(placed
            .iter()
            .filter_map(|(path, other)| {
                let message = match other {
                    Some(other) if other == group => return None,
                    Some(other) => format!(
                        "the group \"{}\" cannot change with {} from the group \"{group_name}\"; change one group per pull request",
                        groups[*other].0,
                        anchor.display()
                    ),
                    None => format!(
                        "{} is in the group \"{group_name}\", so it must be the only change; move this file to its own branch",
                        anchor.display()
                    ),
                };
                Some(Violation::file(*path, message))
            })
            .collect())
    }
}

/// The groups in the order the config gave them. None is an error, so the
/// check never quietly passes everything.
fn groups(config: &Config) -> Result<Vec<(String, GlobSet)>, String> {
    let mut groups: Vec<(String, Vec<&str>)> = Vec::new();
    for (group, pattern) in config.under("groups") {
        match groups.iter_mut().find(|(name, _)| name == group) {
            Some((_, patterns)) => patterns.push(pattern),
            None => groups.push((group.to_string(), vec![pattern])),
        }
    }
    if groups.is_empty() {
        return Err("set groups.NAME to the files in each group".to_string());
    }
    groups
        .into_iter()
        .map(|(name, patterns)| {
            glob_set(&format!("groups.{name}"), &patterns).map(|set| (name, set))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::check::testing::{config, error, run, state};

    const GROUPS: &[(&str, &str)] = &[
        ("groups.agents", "AGENTS.md"),
        ("groups.lint_config", ".credo.exs"),
        ("groups.lint_config", ".check.exs"),
        ("groups.checks", "priv/checks/**"),
    ];

    fn changed(paths: &[&str]) -> State {
        paths
            .iter()
            .fold(state(), |state, path| state.changed(path, "", &[1]))
            .build()
    }

    #[test]
    fn no_grouped_file_passes() {
        let state = changed(&["lib/a.ex", "lib/b.ex"]);
        assert!(run(&SeparatePr, &state, &config(&SeparatePr, GROUPS)).is_empty());
        assert!(run(&SeparatePr, &changed(&[]), &config(&SeparatePr, GROUPS)).is_empty());
    }

    #[test]
    fn files_from_one_group_may_change_together() {
        let state = changed(&[".check.exs", ".credo.exs"]);
        assert!(run(&SeparatePr, &state, &config(&SeparatePr, GROUPS)).is_empty());
    }

    #[test]
    fn a_grouped_file_mixed_with_anything_else_fails_on_the_other_files() {
        let state = changed(&["lib/example/orders.ex", "AGENTS.md", "lib/example/users.ex"]);
        assert_eq!(
            run(&SeparatePr, &state, &config(&SeparatePr, GROUPS)),
            vec![
                "lib/example/orders.ex: AGENTS.md is in the group \"agents\", so it must be the only change; move this file to its own branch",
                "lib/example/users.ex: AGENTS.md is in the group \"agents\", so it must be the only change; move this file to its own branch",
            ]
        );
    }

    #[test]
    fn two_groups_cannot_change_together() {
        let state = changed(&[".credo.exs", "AGENTS.md"]);
        assert_eq!(
            run(&SeparatePr, &state, &config(&SeparatePr, GROUPS)),
            vec![
                "AGENTS.md: the group \"agents\" cannot change with .credo.exs from the group \"lint_config\"; change one group per pull request",
            ]
        );
    }

    #[test]
    fn a_deleted_grouped_file_counts_as_a_change() {
        let state = state().deleted("AGENTS.md").added("lib/a.ex", "").build();
        assert_eq!(run(&SeparatePr, &state, &config(&SeparatePr, GROUPS)).len(), 1);
    }

    #[test]
    fn patterns_match_the_whole_path() {
        let state = changed(&["docs/AGENTS.md", "priv/checks/a.rs", "lib/a.ex"]);
        assert_eq!(
            run(&SeparatePr, &state, &config(&SeparatePr, GROUPS)),
            vec![
                "docs/AGENTS.md: priv/checks/a.rs is in the group \"checks\", so it must be the only change; move this file to its own branch",
                "lib/a.ex: priv/checks/a.rs is in the group \"checks\", so it must be the only change; move this file to its own branch",
            ]
        );
    }

    #[test]
    fn no_groups_or_a_bad_pattern_is_an_error() {
        assert_eq!(
            error(&SeparatePr, &changed(&[]), &config(&SeparatePr, &[])),
            "set groups.NAME to the files in each group"
        );
        let error = error(
            &SeparatePr,
            &changed(&[]),
            &config(&SeparatePr, &[("groups.agents", "[")]),
        );
        assert!(error.starts_with("groups.agents: [ is not a valid pattern"));
    }
}
