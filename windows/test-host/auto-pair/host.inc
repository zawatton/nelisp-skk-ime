DocumentStore* caret_store = nullptr;
bool CaretHostKey(UINT message, WPARAM key, LPARAM flags) {
  if (caret_store && message == WM_CHAR) { caret_store->CaretHostType(static_cast<wchar_t>(key)); return true; }
  if (!caret_store || key != VK_LEFT || (message != WM_KEYDOWN && message != WM_KEYUP)) return false;
  std::printf("CARET_KEY tag=%llx modifiers=%d\n", static_cast<unsigned long long>(GetMessageExtraInfo()),
    (GetKeyState(VK_SHIFT) & 0x8000) != 0);
  caret_store->CaretHostLeft(message == WM_KEYUP, flags);
  return true;
}
