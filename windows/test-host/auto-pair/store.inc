// Chromium-like hosts refresh the committed caret at transaction end.
// A shell accepts text/keys independently of TSF selection changes.
  bool caret_written_ = false, shell_commit_ready_ = false;
  LONG caret_commit_end_ = 0;
  std::wstring shell_, shell_commit_;
  LONG shell_caret_ = 0;
  unsigned left_down_ = 0, left_up_ = 0;
  void CaretHostText(LONG start, ULONG count, const WCHAR* text) {
    caret_written_ = true; caret_commit_end_ = start + static_cast<LONG>(count);
    if (!composition_active_) { shell_commit_.assign(text, count); shell_commit_ready_ = true; }
  }
  void CaretHostEnd() {
    shell_commit_ = buffer_.substr(comp_start_, comp_end_ - comp_start_);
    shell_commit_ready_ = true;
  }
  void CaretHostUnlock() {
    caret_written_ = false;
    if (shell_commit_ready_ && (GetEnvironmentVariableW(L"NATIVEIME_TEST_TERMINAL", nullptr, 0) ||
        GetEnvironmentVariableW(L"NATIVEIME_TEST_CHROMIUM", nullptr, 0))) {
      shell_.insert(shell_caret_, shell_commit_);
      shell_caret_ += static_cast<LONG>(shell_commit_.size());
    }
    shell_commit_ready_ = false;
    // Chromium's commit uses kMoveCursorAfterText. With IsInputIME(),
    // selection-only changes are not propagated to TextInputClient either.
    if (GetEnvironmentVariableW(L"NATIVEIME_TEST_CHROMIUM", nullptr, 0))
      sel_start_ = sel_end_ = shell_caret_;
  }
  void CaretHostLeft(bool up, LPARAM flags) {
    if (locked_) { std::printf("CARET_ERROR before_unlock=1\n"); return; }
    if (!(flags & (static_cast<LPARAM>(1) << 24))) std::printf("CARET_ERROR extended=0\n");
    if (up) ++left_up_;
    else {
      ++left_down_; if (shell_caret_ > 0) --shell_caret_;
      if (GetEnvironmentVariableW(L"NATIVEIME_TEST_CHROMIUM", nullptr, 0))
        sel_start_ = sel_end_ = shell_caret_;
    }
  }
  void CaretHostType(wchar_t ch) { shell_.insert(shell_caret_++, 1, ch); }
  void CaretHostPrint(const std::wstring& token) const {
    std::printf("CARET_HOST token=%s shell=%s caret=%ld left=%u,%u\n",
      Utf8FromWide(token).c_str(), Utf8FromWide(shell_).c_str(), shell_caret_, left_down_, left_up_);
  }
