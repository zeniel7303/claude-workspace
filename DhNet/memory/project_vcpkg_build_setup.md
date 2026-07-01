---
name: project-vcpkg-build-setup
description: "vcpkg manifest-mode install path differs from README; junction created to bridge them; MSBuild needs -p: in git-bash"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0d52f20e-224e-4a32-83d9-db211d48c144
---

`vcpkg.json` exists at repo root (`E:\MyProject\DhNet\vcpkg.json`), so `vcpkg install --triplet x64-windows` run from repo root uses **manifest mode** and installs to `<repo_root>/vcpkg_installed/x64-windows/` (gitignored). The README's build docs and `DhNet_Server.vcxproj`'s include/lib paths instead point at `external\vcpkg\installed\x64-windows\...` (classic mode, where `external/vcpkg` is the vcpkg submodule itself).

**Why:** This mismatch meant protoc/grpc_cpp_plugin and all link libs (grpc, protobuf, openssl, libmysql, abseil, ~76 boost packages) were "missing" from the documented path even though vcpkg install succeeded.

**How to apply:** A directory junction was created: `external/vcpkg/installed` → `<repo_root>/vcpkg_installed` (via `New-Item -ItemType Junction` in PowerShell; `cmd /c mklink /J` failed with a garbled "잘못된 매개 변수" error from git-bash). This junction is local-machine-only (vcpkg's own `.gitignore` already excludes `installed*/`, so it doesn't show up in `git status` for the submodule). If this is a fresh clone/machine, recreate the junction after `vcpkg install` rather than editing `.vcxproj` paths or README.

Also: protoc/grpc_cpp_plugin live at `vcpkg_installed/x64-windows/tools/protobuf/protoc.exe` and `.../tools/grpc/grpc_cpp_plugin.exe` (i.e. `external/vcpkg/installed/...` via the junction) — use these (protobuf 6.33.4#2 / grpc 1.76.0#1) to regenerate `dhnet.pb.{h,cc}`/`dhnet.grpc.pb.{h,cc}`, NOT NuGet Grpc.Tools' bundled protoc (incompatible protobuf version, existing gencode checks `PROTOBUF_VERSION 6033004`).

**MSBuild from git-bash:** `/p:Configuration=Debug` style switches get mangled by MSYS path conversion (`/p:` → becomes part of a path, causes `MSB1008: 프로젝트를 하나만 지정할 수 있습니다`). Use dash-prefixed switches instead: `-p:Configuration=Debug -p:Platform=x64 -m -nologo -v:minimal`. MSBuild.exe path on this machine: `C:\Program Files\Microsoft Visual Studio\18\Professional\MSBuild\Current\Bin\MSBuild.exe` (found via vswhere; README documents a different `...\18\Community\...` path).

**Runtime DLLs for `Binary/Debug/DhNet_Server.exe`:** Current committed `Binary/Debug/*.dll` set (as of commit `35a7cb2`, 2026-06-15): abseil_dll, cares, libcrypto-3-x64, libprotobufd, libssl-3-x64, re2, zlibd1, **libmysql, zd (zlib debug), zstd**. `libmysql.dll` is now a HARD load-time dependency (DhNet_Server.exe directly imports it); without it (or if DLLs are stale vs. vcpkg build) the exe exits immediately with STATUS_ENTRYPOINT_NOT_FOUND or "cannot load libmysql.dll". DB connection failure itself is non-fatal at runtime (logs warning, runs with 0 MySQL worker threads).

**DLL staleness risk:** If vcpkg packages are reinstalled/updated (e.g., after re-running `vcpkg install` or changing `vcpkg.json`), the committed DLL versions fall out of sync with the freshly-linked exe → STATUS_ENTRYPOINT_NOT_FOUND. Fix: copy updated DLLs from `vcpkg_installed/x64-windows/debug/bin/{abseil_dll,cares,libcrypto-3-x64,libprotobufd,libssl-3-x64,re2,libmysql,zd,zstd}.dll` to `Binary/Debug/` and commit them.
