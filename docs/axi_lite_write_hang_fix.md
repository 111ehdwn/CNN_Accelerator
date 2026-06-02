# CSR AXI4-Lite write hang — 원인 · 수정 · 검증

> Arty A7-100T / Vivado·Vitis 2024.1. CSR(`csr_axi`)로의 **첫 write에서 MicroBlaze가 멈추는** 문제의 근본 원인 분석과 수정 기록. 관련 RTL: `RTL/control_status_register/csr_axi_slave_lite_v1_0_csr.v` (수정됨), `axi_inner_ref.v` (원본 데모 템플릿, 레퍼런스로 보존).

---

## 0. 한 줄 요약

Vitis main.c가 `[2] enable...` 직후(첫 `Xil_Out32(0x44A0_0000, ..)`)에서 hang. 원인은 **Xilinx "Create AXI4 Peripheral → Lite" 데모 슬레이브 템플릿의 write FSM 버그** — 핸드셰이크를 `*VALID`/`*READY` 외 내부 state에 의존시키고 `axi_wready`를 reset 후 항상 1로 두어, 마스터/AXI Interconnect가 **W를 AW보다 먼저** 주는 (합법적) 순서에서 BVALID를 영영 안 내보내 master가 stall. **robust handshake**(AWVALID·WVALID 둘 다 떴을 때만 ready 동시 assert, `aw_en` 패턴)로 교체 → 해결. **C 코드/clock/reset 문제 아님.**

---

## 1. 증상 (실보드)

```
=== CNN Accelerator Test (N=100) ===
[1] weights: ...
[1.5] CSR read test...
[1.5] STATUS=0x00000020 (read returned OK)   ← CSR read 정상 (can_load=1)
[2] enable...
<여기서 멈춤>                                   ← 첫 CSR write 에서 hang
```

- **CSR read는 정상** (`STATUS=0x20`, can_load=1 = 정상 초기값).
- **CSR write만 hang** (`csr_ctrl(CTRL_EN)` = `Xil_Out32(0x44A0_0000, 0x1)` 미반환).
- weight BRAM write(`0xC000_0000~`) 수천 개는 통과 → MicroBlaze master·AXI Interconnect 정상.

read/write는 csr 내부에서 **별개 FSM**. read FSM은 정상, write FSM이 멈춤.

---

## 2. 근본 원인

`csr_axi_slave_lite_v1_0_csr.v`(= `axi_inner_ref.v` 템플릿과 write FSM 로직 100% 동일, 주석만 차이)의 write 상태기계:

```
Idle → (reset 해제) awready<=1, wready<=1 → Waddr
Waddr: AWVALID&&AWREADY 면 awaddr latch; WVALID 도 있으면 bvalid; 없으면 → Wdata
Wdata: WVALID 오면 bvalid; 없으면 계속 대기
```

문제점:
1. **`axi_wready`가 reset 직후 1로 세팅된 뒤 영원히 1.** → 마스터가 WVALID를 주면 AW 진행 여부와 무관하게 W beat가 "accepted"됨.
2. **핸드셰이크를 FSM state에 의존.** AXI 규약상 마스터·인터커넥트는 `VALID && READY`가 둘 다 1이면 **무조건** 다음으로 넘어감. 슬레이브가 다른 조건을 걸면 트랜잭션을 놓침.

→ 마스터가 **W를 AW보다 1 cycle 먼저** 주면: W가 `wready=1`로 소비되지만 FSM은 Waddr에서 무시 → 이후 AW가 오면 `Wdata`로 가서 (이미 사라진) W를 영영 대기 → **BVALID 안 나옴 → master stall.** W-before-AW는 합법적 AXI 순서라 슬레이브가 처리해야 하지만 이 템플릿은 못 함.

이 템플릿이 보통 잘 동작하는 건 대다수 마스터가 AW를 W보다 먼저/동시에 주기 때문. 이 BD의 인터커넥트가 CSR로 W를 먼저 주는 타이밍이라 blind spot에 걸림.

---

## 3. 증거

| # | 방법 | 결과 |
|---|---|---|
| A | **sim** (`axi_inner_ref.v` 모듈 직접) | `AW&W 동시` → BVALID OK / `W 1-cycle 먼저` → **HANG** |
| B | **diff** (csr write FSM vs axi_inner_ref) | 로직 100% 동일 (주석만 차이) → 같은 버그 |
| C | **HW** | CSR read OK + write hang (위 §1) |
| D | **외부 출처** | Xilinx AXI-Lite 데모 코드가 2016년부터 broken으로 문서화 (§9) |

- A의 sim 근거: 마스터가 AW+W를 동시에 주는 `tb_system_axi_multi`(기존)는 통과했음 → 그래서 sim/검증에서 안 잡혔음. W-before-AW는 안 두드렸던 것.

---

## 4. 왜 C 코드 문제가 아닌가

- main.c는 weight BRAM 적재도 CSR 제어도 **같은 `Xil_Out32(addr, data)`** 사용. BRAM은 다 통과, CSR write만 hang → 차이는 **슬레이브**(robust Xilinx BRAM ctrl vs 결함 데모 템플릿)지 C가 아님. C가 문제면 BRAM write도 hang.
- 단일 레지스터 write의 **AW/W 채널 상대 타이밍은 MicroBlaze + AXI Interconnect 하드웨어가 결정.** C는 store 하나를 낼 뿐, AXI 채널 순서를 정하지 못함 → "C를 다르게 짜서 회피"는 원리적으로 불가.
- read가 되는 것으로 clock/reset/연결/주소맵(`0x44A0_0000` 할당 확인)은 모두 정상 입증됨.

---

## 5. 수정 (robust handshake, `aw_en` 패턴)

`csr_axi_slave_lite_v1_0_csr.v`의 write 채널만 교체 (read FSM·CTRL/STATUS/TIMER·read mux 보존):

```verilog
reg aw_en;
// awready : AWVALID·WVALID 둘 다 + aw_en 일 때만 1-cycle
always @(posedge clk)
  if (!resetn)                                              {axi_awready,aw_en} <= {1'b0,1'b1};
  else if (~axi_awready && AWVALID && WVALID && aw_en)      {axi_awready,aw_en} <= {1'b1,1'b0};
  else if (BREADY && axi_bvalid)                            {aw_en,axi_awready} <= {1'b1,1'b0};
  else                                                      axi_awready <= 1'b0;
// wready : 동일 조건
always @(posedge clk)
  if (!resetn)                                              axi_wready <= 0;
  else if (~axi_wready && WVALID && AWVALID && aw_en)       axi_wready <= 1;
  else                                                      axi_wready <= 0;
// bvalid : write 성사 시 set, BREADY 에 clear
// slv_reg_wren = axi_wready && WVALID && axi_awready && AWVALID  → CTRL 레지스터 write
```

핵심: **두 채널의 VALID가 모두 떠야** ready를 함께 assert → AW/W 도착 순서 무관. (`*READY`를 내부 state가 아니라 두 `*VALID`에만 의존.)

> `axi_inner_ref.v`(원본 데모 템플릿)는 **삭제하지 않고 레퍼런스로 보존.**

---

## 6. TB 영향 — compliant master 필요

기존 testbench의 AXI master 태스크들은 **READY를 보자마자(1-posedge 후) VALID를 deassert**하는 비-compliant 모델이었음. 이는 transfer를 첫 edge에 끝내던 구 FSM에서만 동작. robust FSM은 transfer가 1 cycle 뒤라, VALID를 **BVALID(write 응답) 볼 때까지 유지**해야 함 (실제 AXI 인터커넥트 거동). 수정:
- `TB/multi_img/tb_system_axi_multi.v` `axi_write`: `while(!BVALID) @(negedge)` 로 VALID 유지.
- (검증용 `tb_csr_write.v`도 동일 패턴.)

---

## 7. 검증 결과 (iverilog)

| TB | 결과 |
|---|---|
| `tb_csr_write` (AW&W 동시 / AW먼저 / W먼저 / W 2-cycle먼저) | **전부 BVALID OK** (수정 전: W먼저 HANG) |
| `tb_system_axi_multi` (PS AXI ↔ CSR ↔ cnn_accelerator, N=10) | **10/10 PASS** (AXI 제어 + result + logit bit-exact) |

---

## 8. 실 HW 적용 (재합성 필요)

1. 수정된 `csr_axi_slave_lite_v1_0_csr.v`로 custom IP **재패키징**(또는 source 갱신).
2. Block Design에서 IP **upgrade** → Validate Design.
3. **Generate Bitstream** → Export Hardware (Include Bitstream) → `.xsa`.
4. Vitis: 새 `.xsa`로 platform 갱신 → main.c 재빌드 → flash.
5. 기대: `[1.5] STATUS=...` 후 `[2] enable... / [2a] start... / [2b] STATUS=...` 정상 진행.

---

## 9. 출처

- [The most common AXI mistake — ZipCPU](https://zipcpu.com/formal/2019/04/16/axi-mistakes.html) — *"if the master presents write data (WVALID) before write address (AWVALID) ... transactions get lost silently—potentially locking the system."* 핸드셰이크를 `*VALID`/`*READY` 외 조건에 의존시키는 게 버그.
- [Fixing Xilinx's Broken AXI-lite Design — ZipCPU](https://zipcpu.com/blog/2021/05/22/vhdlaxil.html) — Xilinx 데모 AXI-Lite 코드가 2016년부터 broken.
- [Building an AXI-Lite slave the easy way (easyaxil) — ZipCPU](https://zipcpu.com/blog/2020/03/08/easyaxil.html) — robust 슬레이브 권장 패턴(두 VALID 동기화).
- [Building the perfect AXI4 slave (demoaxi) — ZipCPU](https://zipcpu.com/blog/2019/05/29/demoaxi.html)
- [AXI4-Lite slave hangs CPU (동종 버그 사례) — Intel Community](https://community.intel.com/t5/Nios-V-II-Embedded-Design-Suite/My-AXI4-Lite-slave-hangs-CPU-after-read-Write-transactions-work/m-p/193427)

---

## 10. 관련 파일

| 파일 | 상태 |
|---|---|
| `RTL/control_status_register/csr_axi_slave_lite_v1_0_csr.v` | **수정** (write 핸드셰이크 robust 교체) |
| `RTL/control_status_register/axi_inner_ref.v` | 보존 (원본 데모 템플릿 레퍼런스) |
| `TB/multi_img/tb_system_axi_multi.v` | `axi_write` compliant master 로 수정 |
| `vitis/main.c` | 변경 없음 (무죄 — §4) |
