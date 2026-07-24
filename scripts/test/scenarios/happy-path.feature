# Executable QA procedure: the canonical green run. Mirrors
# integration-run.sh's assertions; kept as the readable reference for what a
# healthy node-track night-shift produces.
Scenario: happy-path node run completes with archived evidence
  Given a throwaway node project with a red test
  And the claude stub in mode "happy"
  When the engine runs with the spec
  Then the archived run status is "complete"
  And the archived journal is valid jsonl
  And the archived journal contains event "run_complete"
  And the project file "add.js" exists
  And the project test suite passes
