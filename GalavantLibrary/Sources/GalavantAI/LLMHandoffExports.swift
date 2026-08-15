// The external-LLM handoff spine (`HandoffSession`, `HandoffRouting`,
// `HandoffContractMarker`, `HandoffSessionStore`, …) was lifted out of GalavantAI
// into jon-platform's shared `LLMHandoffKit` package (galavant ADR-0036 "the lift"),
// mirroring how the in-app browser became `WebExtractorKit` and the model boundary
// became `LLMClientKit`. Re-export it so existing `import GalavantAI` call sites —
// and the domain code in GalavantSchema that extends `HandoffSession` — keep
// compiling unchanged. Galavant owns the meaning of the opaque source/task tokens
// (see GalavantSchema/RecommendationHandoff.swift); the spine stays domain-free.
@_exported import LLMHandoffKit
