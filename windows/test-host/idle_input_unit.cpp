#include "realtime_frontend.h"
#include "local_ack_fixture.h"
#include <windows.h>
#include <msctf.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <deque>
#include <string>
void Check(bool value, const char* message) { if (!value) { std::printf("FAIL %s\n", message); std::exit(1); } }
constexpr UINT kConfirmationReplayMessage = WM_APP + 0x4e3;
struct ProviderResult { uint64_t sequence = 1; bool settings_pending = false; std::optional<ddskk::EngineState> state; };
struct Anchor { void Release() {} };
class TextService {
public:
 ddskk::RealtimeFrontend realtime_frontend_;
 bool confirmation_delivery_pending_ = false;
 bool confirmation_pending_ = false, confirmation_replay_ = false, confirmation_resume_posted_ = false;
 bool provider_conversion_active_ = false;
 bool provider_conversion_retry_ = false, provider_composition_active_ = false, registration_mode_ = false;
 bool engine_pending_ = false, confirmation_replay_unused = false, engine_roundtrip_failed_ = false;
 bool local_enabled_ = false, provider_cleanup_pending_ = false, okuri_handoff_failed_ = false;
 void* composition_ = nullptr; HWND provider_window_ = nullptr;
 ITfRange* confirmation_anchor_ = nullptr;
 std::optional<ddskk::EngineState> confirmation_state_;
 std::atomic<bool> provider_pending_{false};
 std::atomic<uint64_t> provider_sequence_{1};
 unsigned pending_state_edits_ = 0, loads = 0, edits = 0, replays = 0;
 uint64_t confirmation_dispatch_sequence_ = 0;
 std::deque<int> deferred_provider_keys_;
 struct { std::atomic<bool> dirty{false}; } settings_watcher_;
 struct { void MarkNeedsResync() {} } engine_;
 std::wstring document;
 void RefreshDebugSettings() {}
 void LoadSettings() { ++loads; }
 void MaybeShowModeIndicator(void*, void*) {}
 void CloseCandidateUi() {}
 void RetainProviderConversion() { provider_conversion_retry_ = true; }
 void ResolveLocalFallback() { Check(false, "must not restore/commit raw kana"); }
 void ReplayDeferredProviderKeys() { if (!confirmation_pending_ && !confirmation_replay_) { ++replays; deferred_provider_keys_.clear(); } }
 void CancelPendingProvider() { provider_pending_ = false; provider_conversion_retry_ = false; deferred_provider_keys_.clear(); ++provider_sequence_; }
 HRESULT ApplyLocalState(void*, const ddskk::EngineState& state) { ++edits; document += state.text; return S_OK; }
 void FollowSettings(); void ScheduleConfirmationReplay();
 void ReleaseFailedConfirmation(); void SettleIdleProviderState();
 bool CommitNativeKatakana(ITfContext* context, bool replay = false);
 bool StateEditAllowed(ITfContext*,uint64_t) { return true; }
 void ConfirmationFinished(ITfContext*,uint64_t,HRESULT,ITfRange*);
 bool WouldQueueProviderKey();
 void ApplyEmpty(ProviderResult* result);
};
#include "idle_input.inc"
int main() {
 Check(CountLocalAcks("LOCAL_PENDING id=a\nLOCAL_ACK_WAIT OK\nLOCAL_ACK id=a sequence=1") == 0, "partial ACK accepted");
 Check(CountLocalAcks("LOCAL_ACK id=a sequence=1\nLOCAL_ACK id=a sequence=1\n") == 1, "duplicate ACK advanced fence");
 Check(CountLocalAcks("LOCAL_ACK id=a sequence=1\nLOCAL_ACK id=b sequence=2\n") == 2, "complete ACK fence");
 Check(CountLocalAcks("LOCAL_ACK id=a sequence=0\n") == 0, "invalid ACK sequence accepted");
 TextService s;
 // Space/Enter candidate confirmation: current result is empty after the
 // provider worker becomes idle; an older result is ignored by its sequence.
 s.provider_pending_ = true; s.confirmation_pending_ = true;
 ProviderResult late; late.sequence = 0;
 s.ApplyEmpty(&late);
 Check(s.provider_pending_ && s.confirmation_pending_, "stale result releases live request");
 ProviderResult result;
 s.ApplyEmpty(&result);
 Check(!s.confirmation_pending_, "empty result leaves confirmation_pending stuck");
#ifdef FIXED_IDLE_INPUT
 s.confirmation_pending_ = true;
 s.ConfirmationFinished(nullptr,0,E_FAIL,nullptr);
 Check(!s.confirmation_pending_, "fatal edit keeps confirmation pending");
 s.ConfirmationFinished(nullptr,0,S_OK,nullptr);
 s.ScheduleConfirmationReplay();
 Check(s.confirmation_delivery_pending_ && s.confirmation_replay_, "successful commit lost delivery barrier");
 s.confirmation_delivery_pending_ = false; // Both existing pump boundaries crossed.
 s.ScheduleConfirmationReplay();
 Check(!s.confirmation_replay_, "delivery-complete empty barrier not settled");
#endif
 s.confirmation_replay_ = true;
 s.ScheduleConfirmationReplay();
 Check(!s.confirmation_replay_, "empty confirmation replay waits forever for message pump");
 s.settings_watcher_.dirty = true;
 s.FollowSettings(); Check(s.loads == 1, "DllDebug-style write starved at idle key");
 for (char32_t c : U"Si-kennsyaru") if (c) s.realtime_frontend_.Feed(c);
 Check(s.realtime_frontend_.preview_reading() == L"しーけんしゃる", "exact user reading");
#ifdef FIXED_IDLE_INPUT
 s.provider_pending_ = true; // late/empty conversion cannot own local q.
 Check(s.CommitNativeKatakana(reinterpret_cast<ITfContext*>(&s)), "native q should settle in-flight conversion");
 Check(s.document == L"シーケンシャル" && s.edits == 1, "katakana q exactly one edit");
 Check(!s.provider_pending_ && s.deferred_provider_keys_.empty(), "next keys direct");
 s.ApplyEmpty(&result); // The superseded lookup must not repaint/re-arm anything.
 Check(s.document == L"シーケンシャル" && s.edits == 1 && !s.confirmation_pending_, "late q lookup discarded");
 s.provider_conversion_retry_ = true; // stale retry after document settled.
 s.settings_watcher_.dirty = true; s.FollowSettings();
 Check(!s.provider_conversion_retry_ && s.loads == 2, "idle retry blocks settings");
 Check(!s.WouldQueueProviderKey() && !s.confirmation_replay_ && !s.confirmation_pending_, "next key still routed to deferred queue");
 Check(s.realtime_frontend_.Feed(U'a')->text == L"あ", "next direct native key");
 s.realtime_frontend_.Reset();
 for (char32_t c : U"Si-kennsyaru") if (c) s.realtime_frontend_.Feed(c);
 s.deferred_provider_keys_ = {65,66};
 Check(s.CommitNativeKatakana(reinterpret_cast<ITfContext*>(&s),true), "replayed q used provider");
 Check(s.edits == 2 && s.deferred_provider_keys_ == std::deque<int>({65,66}), "replayed q lost following keys");
 s.deferred_provider_keys_.clear();
 s.confirmation_replay_ = true; s.deferred_provider_keys_.push_back(13);
 s.ScheduleConfirmationReplay(); Check(s.confirmation_replay_, "real queued Enter barrier preserved");
#endif
 std::puts("PASS learning-fence checks=4 distinct_ack=1 partial_ack=0 duplicate_advance=0");
 std::puts("PASS idle-input empty_result=1 next_keys_direct=1 irrelevant_reload=1 katakana_q_edits=1 replay_q_edits=1 following_keys=2 callback_pipe_io=0 stacks=0");
}
