# Changelog

## v1.1.1 - 2026-03-23

### Bug Fix

- Async mode auto-disable: Previously the agent would disable itself after async provision regardless of success/failure. Now it only auto-disables when the script succeeds, matching sync mode behavior.
