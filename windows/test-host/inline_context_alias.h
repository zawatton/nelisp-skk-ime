// SPDX-License-Identifier: GPL-3.0-or-later
// A legal COM tear-off: distinct ITfContext pointer, same IUnknown identity.
class InlineContextAlias final : public ITfContext {
 public:
  explicit InlineContextAlias(ITfContext* context) : context_(context) { context_->AddRef(); }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** out) override {
    if (!out) return E_POINTER;
    if (iid == IID_ITfContext) { *out = static_cast<ITfContext*>(this); AddRef(); return S_OK; }
    return context_->QueryInterface(iid, out);
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
  ULONG STDMETHODCALLTYPE Release() override { auto n = --refs_; if (!n) delete this; return n; }
  HRESULT STDMETHODCALLTYPE RequestEditSession(TfClientId id, ITfEditSession* s, DWORD f, HRESULT* r) override { return context_->RequestEditSession(id,s,f,r); }
  HRESULT STDMETHODCALLTYPE InWriteSession(TfClientId id, BOOL* w) override { return context_->InWriteSession(id,w); }
  HRESULT STDMETHODCALLTYPE GetSelection(TfEditCookie c, ULONG i, ULONG n, TF_SELECTION* s, ULONG* fetched) override { return context_->GetSelection(c,i,n,s,fetched); }
  HRESULT STDMETHODCALLTYPE SetSelection(TfEditCookie c, ULONG n, const TF_SELECTION* s) override { return context_->SetSelection(c,n,s); }
  HRESULT STDMETHODCALLTYPE GetStart(TfEditCookie c, ITfRange** r) override { return context_->GetStart(c,r); }
  HRESULT STDMETHODCALLTYPE GetEnd(TfEditCookie c, ITfRange** r) override { return context_->GetEnd(c,r); }
  HRESULT STDMETHODCALLTYPE GetActiveView(ITfContextView** v) override { return context_->GetActiveView(v); }
  HRESULT STDMETHODCALLTYPE EnumViews(IEnumTfContextViews** v) override { return context_->EnumViews(v); }
  HRESULT STDMETHODCALLTYPE GetStatus(TF_STATUS* s) override { return context_->GetStatus(s); }
  HRESULT STDMETHODCALLTYPE GetProperty(REFGUID g, ITfProperty** p) override { return context_->GetProperty(g,p); }
  HRESULT STDMETHODCALLTYPE GetAppProperty(REFGUID g, ITfReadOnlyProperty** p) override { return context_->GetAppProperty(g,p); }
  HRESULT STDMETHODCALLTYPE TrackProperties(const GUID** p, ULONG n, const GUID** a, ULONG m, ITfReadOnlyProperty** r) override { return context_->TrackProperties(p,n,a,m,r); }
  HRESULT STDMETHODCALLTYPE EnumProperties(IEnumTfProperties** p) override { return context_->EnumProperties(p); }
  HRESULT STDMETHODCALLTYPE GetDocumentMgr(ITfDocumentMgr** d) override { return context_->GetDocumentMgr(d); }
  HRESULT STDMETHODCALLTYPE CreateRangeBackup(TfEditCookie c, ITfRange* r, ITfRangeBackup** b) override { return context_->CreateRangeBackup(c,r,b); }
 private:
  ~InlineContextAlias() { context_->Release(); }
  ITfContext* context_;
  ULONG refs_ = 1;
};
