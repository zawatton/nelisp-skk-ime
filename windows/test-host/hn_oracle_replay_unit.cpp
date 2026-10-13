// Offline production-owner replay: no host entry, child, stack or registry IO.
#include <iostream>
#define wmain host_program_main
#include "../host/main.cpp"
#undef wmain
namespace { namespace native_adapter {
struct ShadowPolicyTest {
  static void OwnerSelection() {
    ShadowPolicy policy;
    auto check=[](bool ok) { if (!ok) throw std::runtime_error("owner selection"); };
    for (auto op : {hn3::Operation::Builtins, hn3::Operation::Server, hn3::Operation::Dictionary,
                    hn3::Operation::Quote, hn3::Operation::Startup}) {
      hn3::Frame frame; frame.operation=op; frame.fields={"unit"};
      if (op==hn3::Operation::Server) frame.fields.push_back("unit");
      if (op==hn3::Operation::Startup) frame.fields.resize(8,"0");
      frame.engine_epoch=engine_epoch; frame.generation=publication_generation;
      const auto key=hn3::Encode(frame);
      for (unsigned mode : {0u,1u,2u}) {
        policy.byte_modes_.fill(mode); policy.healthy_=true; policy.hn3_capable_=true;
        policy.byte_memo_[key]="elisp";
        bool managed=true; int native=0;
        const auto result=policy.Bytes<true>(op,frame.fields,0,[&] { ++native; return std::string("cpp"); },&managed);
        check(result==(mode==1 ? "elisp" : "cpp") && managed==(mode==1) && native==(mode==1 ? 0 : 1));
        check(policy.byte_queue_.empty());
      }
    }
    policy.Invalidate(); policy.byte_modes_.fill(1);
    policy.healthy_=true; // HP2-only peer: production keeps native fallback.
    bool managed=true;
    check(policy.Bytes<true>(hn3::Operation::Dictionary,{std::string(131072,'x')},0,
        [] { return std::string("cpp"); },&managed)=="cpp" && !managed);
    check(policy.Bytes(hn3::Operation::Dictionary,{"unit"},0,[] { return std::string("cpp"); })=="cpp");
    try {
      policy.Bytes<true>(hn3::Operation::Dictionary,{"unit"},0,[] { return std::string("cpp"); });
      throw std::runtime_error("unavailable owner accepted");
    } catch (const ReplayUnavailable&) {}
    policy.Invalidate();
    hn3::Frame frame; frame.operation=hn3::Operation::Dictionary; frame.fields={"warm"};
    frame.engine_epoch=engine_epoch; frame.generation=publication_generation;
    std::jthread ready([&] {
      Sleep(20); std::lock_guard lock(policy.mutex_);
      policy.healthy_=true; policy.hn3_capable_=true; policy.byte_memo_[hn3::Encode(frame)]="elisp";
      policy.changed_.notify_all();
    });
    const auto result=policy.Bytes<true>(frame.operation,frame.fields,GetTickCount64()+500,
        [] { return std::string("cpp"); },&managed);
    ready.join(); check(result=="elisp" && managed && policy.ReplayReady());
    // A consumed reply fenced by publication is rejected without retiring IPC.
    HANDLE input_read=nullptr, output_write=nullptr;
    check(CreatePipe(&input_read,&policy.input_,nullptr,4096) && CreatePipe(&policy.output_,&output_write,nullptr,4096));
    policy.process_=GetCurrentProcess();
    auto work=std::make_shared<ShadowPolicy::ByteRequest>(); work->frame=frame; work->deadline=GetTickCount64()+500;
    auto reply=frame; reply.reply=true; reply.correlation=policy.request_+1; reply.policy_epoch=policy.epoch_;
    reply.fields={"elisp"}; const auto wire=hn3::Encode(reply); DWORD written=0;
    check(WriteFile(output_write,wire.data(),static_cast<DWORD>(wire.size()),&written,nullptr));
    ++publication_generation;
    check(policy.ByteExchange(work) && work->done && !work->valid && policy.ReplayReady());
    --publication_generation;
    CloseHandle(input_read); CloseHandle(output_write); CloseHandle(policy.input_); CloseHandle(policy.output_);
    policy.input_=policy.output_=policy.process_=nullptr;
    policy.Invalidate();
    std::fprintf(stderr,"PASS owner selection operations=5 modes=off/elisp/shadow HP2-fallback=1 readiness=1 stale-stream=1 stacks=0 children=0\n");
  }
  static void ManagedHooks(const std::filesystem::path& directory) {
    shadow.byte_modes_.fill(1); shadow.healthy_=true; shadow.hn3_capable_=false;
    const auto unavailable=directory/"unavailable.request";
    std::filesystem::remove(unavailable.wstring()+L".reply");
    std::string input; hn3::Put(input,12,4); input+="builtin-unit";
    std::ofstream source(unavailable,std::ios::binary); source.write(input.data(),input.size()); source.close();
    if (OracleReplay(OracleHex(WideToUtf8(unavailable.wstring())))!="ERR HN ORACLE UNAVAILABLE" ||
        std::filesystem::exists(unavailable.wstring()+L".reply")) throw std::runtime_error("unavailable hook wrote fallback evidence");
    shadow.byte_modes_.fill(1); shadow.healthy_=true; shadow.hn3_capable_=true;
    auto probe=[&](hn3::Operation op, const std::string& name, const std::vector<std::string>& inputs,
                   const std::vector<std::string>& fields, const std::string& expected) {
      hn3::Frame frame; frame.operation=op; frame.fields=fields;
      frame.engine_epoch=engine_epoch; frame.generation=publication_generation;
      const auto key=hn3::Encode(frame);
      shadow.byte_memo_[key]=expected;
      std::string body;
      auto put=[&](const std::string& field) { hn3::Put(body,field.size(),4); body+=field; };
      put(name); for (const auto& input : inputs) put(input);
      const auto path=directory/(name+".request");
      std::filesystem::remove(path.wstring()+L".reply");
      std::ofstream out(path,std::ios::binary); out.write(body.data(),body.size()); out.close();
      if (OracleReplay(OracleHex(WideToUtf8(path.wstring())))!="OK HN ORACLE elisp") throw std::runtime_error("managed hook dispatch");
      std::ifstream reply(path.wstring()+L".reply",std::ios::binary);
      const std::string bytes((std::istreambuf_iterator<char>(reply)),{});
      if (op!=hn3::Operation::Startup && bytes.substr(4,hn3::Get(bytes,0,4))!=expected) throw std::runtime_error("managed exact bytes");
      if (op==hn3::Operation::Startup && bytes.find(OracleWide(L"sentinel"))==bytes.npos) throw std::runtime_error("managed startup selection");
      if (!shadow.byte_queue_.empty()) throw std::runtime_error("unexpected hook IPC");
    };
    probe(hn3::Operation::Builtins,"builtin-unit",{"/x/","/y/"},{"/x/","/y/"},"managed-builtins");
    probe(hn3::Operation::Server,"server-unit",{"/x/","/y/"},{"/x/","/y/"},"managed-server");
    probe(hn3::Operation::Dictionary,"engine-unit",{"1/x/"},{"1/x/"},"managed-LIST");
    probe(hn3::Operation::Quote,"quote-unit",{"x"},{"x"},"managed-quote");
    std::vector<std::string> fields={"0","","1","0","0","0","","0","0","7"};
    for (const auto* name : kStartupRegistry) {
      fields.push_back(WideToUtf8(name)); fields.insert(fields.end(),{"0","0","0","","0"});
    }
    hn3::Frame plan; plan.reply=true; plan.operation=hn3::Operation::Startup;
    plan.fields={"framework","load","sentinel","0","1","set","NELISP_IME_ENGINE","sentinel"};
    probe(hn3::Operation::Startup,"startup-unit",{"0,1,0",""},fields,hn3::Encode(plan));
    shadow.Invalidate(); shadow.byte_modes_.fill(0);
    std::fprintf(stderr,"PASS managed hook memo dispatch operations=5 children=0 IPC=0\n");
  }
};
} }
int main(int argc, char** argv) {
  if (argc!=3) return 2;
  if (std::string(argv[1])=="--old-only") {
    const bool enabled=native_adapter::ShadowPolicy::HarnessOldOnlyPeer();
    std::printf("HP2-only enabled=%d stacks=0 children=0\n",enabled);
    return enabled==(std::string(argv[2])=="1") ? 0 : 1;
  }
  int checks=0;
  auto check=[&](bool ok) { ++checks; if (!ok) throw std::runtime_error("inertness check "+std::to_string(checks)); };
  try {
    SetEnvironmentVariableW(L"DDSKK_HOST_POLICY_COUNTERS",L"1");
    SetEnvironmentVariableW(L"DDSKK_PIPE_NAME",L"\\\\.\\pipe\\ddskk-test-unit");
    SetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY",L"Software\\NativeIME-test-unit");
    SetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",nullptr);
    check(OracleReplay("not-a-path")=="ERR HN ORACLE DISABLED");
    SetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",L"0");
    check(OracleReplay("not-a-path")=="ERR HN ORACLE DISABLED");
    SetEnvironmentVariableW(L"DDSKK_HARNESS_DIAGNOSTICS",L"1");
    SetEnvironmentVariableW(L"DDSKK_PIPE_NAME",kPipeName);
    check(OracleReplay("not-a-path")=="ERR HN ORACLE DISABLED");
    SetEnvironmentVariableW(L"DDSKK_PIPE_NAME",L"\\\\.\\pipe\\ddskk-test-unit");
    SetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY",L"Software\\NativeIME");
    check(OracleReplay("not-a-path")=="ERR HN ORACLE DISABLED");
    SetEnvironmentVariableW(L"NATIVEIME_REGISTRY_KEY",L"Software\\NativeIME-test-unit");
    check(startup_replay::current==nullptr && g_startup_imported.empty() && g_builtin_dictionary.maps.empty());
    std::wstring directory, fixture;
    check(HnWide(argv[1],directory) && HnWide(argv[2],fixture));
    SetEnvironmentVariableW(L"DDSKK_HOST_ORACLE_DIR",directory.c_str());
    g_log_path=(std::filesystem::path(directory)/"owner-selection.log").wstring();
    std::filesystem::remove(g_log_path);
    size_t count=0; std::unordered_map<std::string,std::string> map;
    check(LoadDictionaryFile(fixture,&map,&count));
    g_builtin_dictionary.maps.push_back(std::move(map)); g_builtin_dictionary.ready=true;
    const auto unchanged=g_builtin_dictionary.maps;
    std::ifstream source(fixture,std::ios::binary);
    const std::string contents((std::istreambuf_iterator<char>(source)),{});
    const auto local=ddskk::local::CompileSources({ddskk::local::ParseDictionary(contents,true).entries},7);
    const auto alpha=ddskk::local::SerializeCandidates(local.at(ddskk::local::VariantKey("alpha",'N')).candidates);
    std::fprintf(stderr,"DIAG compiled-index alpha_hex=%s frozen-builtin alpha_hex=%s\n",
        OracleHex(alpha).c_str(),OracleHex(MergeBuiltinCandidates("alpha")).c_str());
    const auto env=StartupEnvironment(L"NELISP_IME_ENGINE");
    startup_replay::Snapshot fake; fake.env[L"NELISP_IME_ENGINE"]=L"private-sentinel";
    startup_replay::current=&fake;
    check(StartupEnvironment<true>(L"NELISP_IME_ENGINE")==L"private-sentinel");
    check(StartupEnvironment(L"NELISP_IME_ENGINE")==env); // normal instantiation ignores the seam
    startup_replay::current=nullptr;
    std::string wire;
    while (std::getline(std::cin,wire)) {
      std::cout << OracleReplay(wire) << '\n';
      check(startup_replay::current==nullptr && g_startup_imported.empty());
      check(StartupEnvironment(L"NELISP_IME_ENGINE")==env);
      check(g_builtin_dictionary.maps==unchanged);
    }
    native_adapter::ShadowPolicyTest::OwnerSelection();
    native_adapter::ShadowPolicyTest::ManagedHooks(directory);
    check(startup_replay::current==nullptr && g_startup_imported.empty() && g_builtin_dictionary.maps==unchanged);
    std::fprintf(stderr,"PASS oracle hook inertness checks=%d stacks=0 children=0\n",checks);
    return 0;
  } catch (const std::exception& e) { std::fprintf(stderr,"FAIL %s\n",e.what()); return 1; }
}
