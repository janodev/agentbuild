# Notika performance summary oracles

The heavy and light raw reports and matching summaries come from Notika's
committed 9 September 2026 indexed native Text measurements under
`Docs/Technical/ArchitectureRefactor/Evidence/`. The original filenames are
`text-native-input-heavy-dependencies[-summary]-20260909-indexed.json` and
`text-native-input-production-refresh[-summary]-20260909-indexed.json`.

These copies retain every JSON value and numeric type while removing whitespace.
The summaries were produced by Notika's existing Python analyzer before the
Swift implementation. Tests compare their complete contents against independent
Swift reproduction; they do not run or import the Python controller.

The fixture revision and source hash are historical observations. They are not
evidence about the current checkout, current hardware, or a new benchmark run.
