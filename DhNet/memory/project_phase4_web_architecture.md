---
name: project-phase4-web-architecture
description: "Phase 4 admin API direction - web layer stays C#/ASP.NET, extend gRPC AdminService instead of cpp-httplib"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0d52f20e-224e-4a32-83d9-db211d48c144
---

Phase 4 (admin REST API) extends the existing gRPC AdminService (C++, `DhNet_Server/DhNet_Server/AdminGrpcServer.*`, `AdminController.*`) ↔ DhNet_Web (ASP.NET Core REST gateway, `DhNet_Server/DhNet_Web`) architecture, NOT the README's old "cpp-httplib REST API" plan.

**Why:** User explicitly decided to keep the web layer in C# ("웹 쪽은 기존대로 c#으로 유지했으면 좋겠어"). README has been updated to reflect this (Phase 4 row now says "gRPC AdminService 확장 + ASP.NET Core REST 게이트웨이").

**How to apply:** When adding new admin endpoints, follow the established pattern: proto message/RPC in `dhnet.proto` → System method (READ_LOCK snapshot, e.g. `PlayerSystem::GetPlayers()`) → `AdminController` function using `DispatchToLogicThreadWithTimeout` → `AdminServiceImpl` gRPC handler in `AdminGrpcServer.*` → `IAdminClient`/`GrpcAdminClient` (C#) → new/extended Controller in `DhNet_Web/Controllers`. See [[project-vcpkg-build-setup]] for the build toolchain.

**Implemented endpoints (all committed 2026-06-15, commit `738a626`):**
- `GET  /players` — ListPlayers RPC, `PlayerSystem::GetPlayers()` (reference/template impl)
- `POST /players/{id}/kick` — KickPlayer RPC, `Session::Disconnect(L"Kicked by admin")`; action pattern (success/detail fields, GrpcAdminClient throws `RpcException(Unknown)` on false)
- `GET  /lobbies` — ListLobbies RPC, `LobbySystem::GetLobbies()`; returns all lobby slots with playerCount/capacity

**Next:** server stats, room broadcast improvements, or other admin actions.
