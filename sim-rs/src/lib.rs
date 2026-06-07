//! Addendum sim core, ported from canonical Lua (sim/*.lua). u32 wrapping ops
//! mirror the Lua `% 2^32` discipline; cross-validated vs luajit goldens.
pub mod rng;
pub mod namegen_data;
pub mod namegen;
pub mod logo_data;
pub mod logo;
pub mod wasm;
pub mod wasm_call;
pub mod composer;
pub mod diagnosis;
pub mod fatigue;
pub mod funnel;
pub mod ledger;
pub mod significance;
pub mod shimmer;
pub mod team;
pub mod director;
pub mod economy;
pub mod resonance;
pub mod content;
pub mod strategist;
pub mod wave;
pub mod game;
pub mod demo;
pub mod bots;

#[cfg(test)]
mod economy_tests;
