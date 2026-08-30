//! Memory cache: the byte-budget LRU in front of the disk cache.
//!
//! Three things make this tier exist rather than leaving every read on disk:
//!
//! * a turn that lands on a prefetched page gets its bytes without a file read,
//!   which is the difference between a smooth flip and a hitch on a 24 MB page,
//! * the reader's hot set (the visible spread plus its neighbours) stays pinned
//!   no matter how many other pages are open in the session,
//! * and because the tier is *budgeted*, it cannot be the thing that OOMs a
//!   long reading session — the whole point of Stage 8 is that memory stays
//!   flat over 500 pages, so growth here is bounded by construction and
//!   measured by the stress harness.
//!
//! Rules that the tests pin down:
//!
//! * `used()` never exceeds `budget()` after any operation, including `insert`.
//! * An item larger than the whole budget is refused, not stored and not
//!   allowed to evict everything else for it.
//! * Re-inserting a key replaces its bytes rather than growing the tier.
//! * Eviction is by least-recently-*used*, with a monotonic sequence number
//!   rather than wall-clock time, so two runs with the same operations produce
//!   the same victim even when the clock has millisecond ties.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::Arc;

#[derive(Clone, Debug)]
struct Slot {
    bytes: Arc<[u8]>,
    size: i64,
    seq: u64,
}

/// Counters the stress harness reads to prove the tier is bounded and warm.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub entries: usize,
    pub bytes: i64,
    /// The ceiling this tier was holding to when the snapshot was taken.
    pub budget_bytes: i64,
    pub peak_bytes: i64,
    pub hits: u64,
    pub misses: u64,
    /// Entries dropped to stay inside the budget.
    pub evictions: u64,
    /// Insertions refused because the item alone exceeded the budget.
    pub refused_oversized: u64,
}

pub struct MemoryCache {
    budget: i64,
    used: i64,
    seq: u64,
    slots: HashMap<String, Slot>,
    /// seq -> key, so the oldest entry is one `pop_first` away.
    order: BTreeMap<u64, String>,
    hits: u64,
    misses: u64,
    evictions: u64,
    refused_oversized: u64,
    peak_bytes: i64,
}

impl MemoryCache {
    pub fn new(budget: i64) -> Self {
        MemoryCache {
            budget: budget.max(0),
            used: 0,
            seq: 0,
            slots: HashMap::new(),
            order: BTreeMap::new(),
            hits: 0,
            misses: 0,
            evictions: 0,
            refused_oversized: 0,
            peak_bytes: 0,
        }
    }

    pub fn budget(&self) -> i64 {
        self.budget
    }

    pub fn used(&self) -> i64 {
        self.used
    }

    pub fn len(&self) -> usize {
        self.slots.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slots.is_empty()
    }

    pub fn stats(&self) -> Stats {
        Stats {
            entries: self.slots.len(),
            bytes: self.used,
            budget_bytes: self.budget,
            peak_bytes: self.peak_bytes,
            hits: self.hits,
            misses: self.misses,
            evictions: self.evictions,
            refused_oversized: self.refused_oversized,
        }
    }

    /// Reset the counters without touching contents: one phase of a stress run
    /// should not inherit the previous phase's numbers.
    pub fn reset_stats(&mut self) {
        self.hits = 0;
        self.misses = 0;
        self.evictions = 0;
        self.refused_oversized = 0;
        self.peak_bytes = self.used;
    }

    /// Shrink or grow the tier. Growing never admits entries back — a page that
    /// was evicted has to come from disk again.
    pub fn set_budget(&mut self, budget: i64) {
        self.budget = budget.max(0);
        self.trim_to_budget();
    }

    pub fn contains(&self, key: &str) -> bool {
        self.slots.contains_key(key)
    }

    /// Copy out a entry and stamp it as most recently used.
    pub fn get(&mut self, key: &str) -> Option<Arc<[u8]>> {
        let Some(slot) = self.slots.get_mut(key) else {
            self.misses += 1;
            return None;
        };
        self.seq += 1;
        let previous = slot.seq;
        slot.seq = self.seq;
        self.order.remove(&previous);
        self.order.insert(self.seq, key.to_string());
        self.hits += 1;
        Some(slot.bytes.clone())
    }

    /// Look without disturbing recency — used to decide whether a page worth
    /// keeping is still resident.
    pub fn peek(&self, key: &str) -> Option<Arc<[u8]>> {
        self.slots.get(key).map(|slot| slot.bytes.clone())
    }

    /// Store bytes, evicting the least recently used entries as needed.
    /// Returns false when the item cannot fit even in an empty tier; the caller
    /// then falls back to disk, which is always correct.
    pub fn insert(&mut self, key: &str, bytes: &[u8]) -> bool {
        self.insert_arc(key, Arc::from(bytes))
    }

    pub fn insert_arc(&mut self, key: &str, bytes: Arc<[u8]>) -> bool {
        let size = bytes.len() as i64;
        if size > self.budget {
            self.refused_oversized += 1;
            return false;
        }
        if let Some(previous) = self.slots.get(key) {
            self.used -= previous.size;
            self.order.remove(&previous.seq);
        }
        // Room is made for the incoming entry, not after it lands, so `used`
        // never transiently exceeds the budget.
        while self.used + size > self.budget {
            match self.order.keys().next().copied() {
                Some(oldest_seq) => {
                    let Some(oldest_key) = self.order.get(&oldest_seq).cloned() else {
                        break;
                    };
                    self.evictions += 1;
                    self.remove(&oldest_key);
                }
                None => break,
            }
        }
        self.seq += 1;
        self.order.insert(self.seq, key.to_string());
        self.slots.insert(
            key.to_string(),
            Slot {
                bytes,
                size,
                seq: self.seq,
            },
        );
        self.used += size;
        self.peak_bytes = self.peak_bytes.max(self.used);
        true
    }

    /// Drop one entry, handing back its bytes.
    pub fn remove(&mut self, key: &str) -> Option<Arc<[u8]>> {
        let slot = self.slots.remove(key)?;
        self.order.remove(&slot.seq);
        self.used -= slot.size;
        Some(slot.bytes)
    }

    pub fn clear(&mut self) {
        self.slots.clear();
        self.order.clear();
        self.used = 0;
    }

    /// Keep only `keys`, dropping the rest. What a fast flip needs: the old
    /// window's bytes are dead weight the moment the center moves past them.
    pub fn retain(&mut self, keys: &HashSet<String>) -> usize {
        let stale: Vec<String> = self
            .slots
            .keys()
            .filter(|key| !keys.contains(*key))
            .cloned()
            .collect();
        let count = stale.len();
        for key in stale {
            self.remove(&key);
        }
        count
    }

    /// Free the LRU tail until the tier fits its budget.
    fn trim_to_budget(&mut self) {
        while self.used > self.budget {
            let Some(oldest_seq) = self.order.keys().next().copied() else {
                break;
            };
            let Some(key) = self.order.get(&oldest_seq).cloned() else {
                break;
            };
            self.evictions += 1;
            self.remove(&key);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put(cache: &mut MemoryCache, key: &str, size: usize) -> bool {
        cache.insert(key, &vec![b'x'; size])
    }

    const KB: i64 = 1024;

    #[test]
    fn insert_get_remove_round_trips_with_accounting() {
        let mut cache = MemoryCache::new(10 * KB);
        assert_eq!(cache.get("a"), None);
        assert_eq!(cache.stats().misses, 1);
        assert!(put(&mut cache, "a", 4 * KB as usize));
        assert_eq!(cache.used(), 4 * KB);
        assert_eq!(cache.len(), 1);
        assert_eq!(cache.get("a").map(|bytes| bytes.len()), Some(4096));
        assert_eq!(cache.stats().hits, 1);
        assert_eq!(cache.remove("a").map(|bytes| bytes.len()), Some(4096));
        assert_eq!(cache.used(), 0);
        assert!(cache.is_empty());
        assert_eq!(cache.remove("a"), None, "removing twice is not an error");
    }

    #[test]
    fn re_inserting_a_key_replaces_rather_than_grows() {
        let mut cache = MemoryCache::new(10 * KB);
        assert!(put(&mut cache, "a", 4 * KB as usize));
        assert!(put(&mut cache, "a", 6 * KB as usize));
        assert_eq!(cache.used(), 6 * KB, "the same key must not double-count");
        assert_eq!(cache.len(), 1);
        assert_eq!(cache.stats().evictions, 0);
        assert_eq!(cache.get("a").map(|bytes| bytes.len()), Some(6144));
    }

    /// The property the acceptance list depends on: no sequence of inserts ever
    /// leaves the tier holding more than it was given.
    #[test]
    fn the_tier_never_exceeds_its_budget_under_sustained_load() {
        let budget = 64 * KB;
        let mut cache = MemoryCache::new(budget);
        for index in 0..500u32 {
            // 3 KiB pages: 21 fit, so this evicts on nearly every insert.
            assert!(put(&mut cache, &format!("p{index}"), 3072));
            assert!(
                cache.used() <= cache.budget(),
                "over budget at {index}: {}",
                cache.used()
            );
        }
        let stats = cache.stats();
        assert_eq!(stats.entries, 21, "64KiB / 3KiB = 21 whole pages");
        assert_eq!(stats.peak_bytes, 63 * KB, "21 * 3KiB, and never more");
        assert!(stats.evictions >= 470);
    }

    #[test]
    fn eviction_is_least_recently_used_not_least_recently_inserted() {
        let mut cache = MemoryCache::new(10 * KB);
        put(&mut cache, "a", 3 * KB as usize);
        put(&mut cache, "b", 3 * KB as usize);
        put(&mut cache, "c", 3 * KB as usize);
        // Touch "a" so it becomes the newest; insertion order would lose it.
        assert!(cache.get("a").is_some());
        put(&mut cache, "d", 3 * KB as usize);
        assert!(cache.contains("a"), "a was used most recently");
        assert!(
            !cache.contains("b"),
            "b is the oldest untouched entry, so b is the victim"
        );
        assert!(cache.contains("c"));
        assert!(cache.contains("d"));
    }

    #[test]
    fn an_item_larger_than_the_budget_is_refused_not_stored() {
        let mut cache = MemoryCache::new(4 * KB);
        put(&mut cache, "small", 2 * KB as usize);
        assert!(!put(&mut cache, "huge", 5 * KB as usize));
        assert_eq!(cache.stats().refused_oversized, 1);
        assert!(
            cache.contains("small"),
            "a refusal must not evict what is already resident"
        );
        assert_eq!(cache.used(), 2 * KB);
    }

    #[test]
    fn shrinking_the_budget_evicts_from_the_tail() {
        let mut cache = MemoryCache::new(12 * KB);
        for key in ["a", "b", "c"] {
            put(&mut cache, key, 4 * KB as usize);
        }
        assert_eq!(cache.used(), 12 * KB);
        cache.set_budget(8 * KB);
        assert_eq!(cache.used(), 8 * KB);
        assert!(!cache.contains("a"));
        assert!(cache.contains("b") && cache.contains("c"));
        cache.set_budget(0);
        assert!(cache.is_empty());
    }

    #[test]
    fn retain_keeps_exactly_the_live_window() {
        let mut cache = MemoryCache::new(20 * KB);
        for key in ["p1", "p2", "p3", "p4"] {
            put(&mut cache, key, 2 * KB as usize);
        }
        let keep: HashSet<String> = ["p2", "p3"].iter().map(|k| k.to_string()).collect();
        assert_eq!(cache.retain(&keep), 2);
        assert_eq!(cache.used(), 4 * KB);
        assert!(!cache.contains("p1") && !cache.contains("p4"));
        assert!(cache.contains("p2") && cache.contains("p3"));
    }

    #[test]
    fn peek_does_not_change_recency() {
        let mut cache = MemoryCache::new(10 * KB);
        put(&mut cache, "a", 3 * KB as usize);
        put(&mut cache, "b", 3 * KB as usize);
        assert!(cache.peek("a").is_some());
        assert_eq!(cache.stats().hits, 0, "a peek is not a use");
        put(&mut cache, "c", 3 * KB as usize);
        put(&mut cache, "d", 3 * KB as usize);
        assert!(
            !cache.contains("a"),
            "peeking left 'a' as the oldest real use, so it went first"
        );
    }

    #[test]
    fn reset_stats_clears_counters_but_not_contents() {
        let mut cache = MemoryCache::new(10 * KB);
        put(&mut cache, "a", 2 * KB as usize);
        cache.get("a");
        cache.reset_stats();
        let stats = cache.stats();
        assert_eq!((stats.hits, stats.misses, stats.evictions), (0, 0, 0));
        assert_eq!(stats.entries, 1);
        assert_eq!(stats.peak_bytes, 2 * KB, "peak restarts at what is held");
    }
}
