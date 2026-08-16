# Testing Principles

These principles guide the keep-tests-tight pass and any test work in this repository. The goal is a fast, trustworthy, high-signal suite — not a large one.

## Fewer, longer tests

- Prefer a small number of tests that each assert a meaningful behavior over many tiny tests.
- Combine related one-assertion tests into a single test that walks a scenario.

## No tiny one-assertion tests

- A test that asserts a single trivial fact (a getter, a constant, a one-line helper) is usually low-signal.
- Delete or fold it into a broader test unless it guards a real regression.

## No pinned copy

- Do not assert on incidental copy, error-message wording, or formatting that is not part of the contract.
- Pin behavior, not strings.

## No tests for type-system guarantees

- Do not write tests that merely re-assert what the compiler already guarantees (e.g. that a function returns a typed value).
- The type system is the test for those.

## High-signal only

- Keep tests that validate real end-user journeys and documented business rules.
- Delete tests for edge cases that cannot happen, duplicate coverage, and tests that only assert incidental copy.

## Keep the suite fast

- Remove tests that are slow for their signal value.
- Prefer focused tests over broad, slow integration tests where the behavior is unit-testable.
