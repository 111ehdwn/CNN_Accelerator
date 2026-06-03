# 300MHz Overclock — 설계 / 구현 노트

CNN Accelerator(Arty A7-100T, `xc7a100t-csg324-1`, speed grade **−1**)의 PL datapath를
**100MHz → 300MHz** 로 올려 latency를 ~3× 단축하는 작업의 설계 결정·구현·BD 절차·검증 정리.

- **현황(committed `4c5dedb` @dohyun):** N=10000 **0.188s, class match 10000/10000 @100MHz**. 누적 5.8×(DMA까지). **가속기-bound**(conv2 throughput floor ~1798 cyc/img).
- **목표:** 가속기 datapath만 300MHz → wall-clock ~3× 단축(~0.063s 기대). **firmware 무변경**(cycle 거동 동일, timer가 세는 100MHz cycle 수가 ~1/3로 줄어 wall-clock 단축).
- **데이터패스 300MHz prep는 이미 완료**(BMG L=2 + 파이프라이닝, iverilog 검증). 이번 작업은 **클럭 분리 + 클럭도메인횡단(CDC) + timing 제약**.

---

## 1. 왜 "가속기만" 300MHz인가 — 전체 오버클럭은 불가/무의미

> 자주 나오는 오해: "전체를 한 클럭(300)으로 올리면 CDC가 필요 없지 않나?" — 논리는 맞지만(단일 도메인=CDC 불필요), 이 보드에선 **전체 300이 불가능**해서 성립 안 함.

### 1.1 진짜 이유 — MicroBlaze + AXI fabric의 timing closure (고칠 수 없음)
- MicroBlaze, AXI Interconnect, AXI BRAM Ctrl, CDMA, UART는 **암호화된 고정 Xilinx IP** → 소스를 못 고쳐 **재파이프라인 불가**.
- Artix-7 **−1(최저 속도 등급)** 에서 이들의 Fmax는 300MHz(3.33ns)에 한참 못 미침. 닫지 못하는 WNS를 고칠 방법이 없음.

### 1.2 실증 데이터 (커뮤니티 + 벤더)
| 출처 | 수치 | 의미 |
|---|---|---|
| MicroBlaze Ref Guide **UG984** | Fmax **267MHz** | **best-case**(캐시 無, 옵션 최소). 우리 BD는 I/D-cache ON → 한참 아래 |
| **viktor-nikolov** MicroBlaze-DDR3-tutorial (Arty A7, **거의 동일 셋업**) | **200MHz → `[Timing 38-282] failed`** (MicroBlaze 내부 negative slack), **100MHz → 안전(slack 양수)** | 같은 보드에서 200도 못 닫음. 100이 표준 |
| AXI SmartConnect 성능표 | Artix-7 **−2** 에서 단순구성 ~516, packet-FIFO ~200 | −1 + 멀티포트 + 512b 컨버터(fcw)면 300 불가 |
| AXI UART Lite **PG142** | 최저 등급 **120MHz** | AXI 주변장치 −1 한계 ~120 |

→ **우리 BD가 전 시스템을 100MHz(`clk_out1`)로 도는 바로 그 이유.** 200도 위험한데 300은 논외.

### 1.3 MIG는 blocker가 아님 (중요한 정정)
- DDR3 MIG는 **원래부터 자기 `ui_clk`(≈81.25MHz) 도메인**에서 돌고, **AXI Interconnect의 clock converter**로 접속함. 지금도 `ram_interconnect`가 100↔81.25를 자동 횡단(M00만 81.25).
- 따라서 나머지를 100에 두든 300으로 올리든 **MIG는 그대로 제 도메인 + AXI converter** → MIG가 무엇을 막거나 강제하지 않음.
- (`ui_clk`/`clk_ref_i`(200, IDELAYCTRL)/DDR3 rate는 모두 **설정 가능** — "200 고정"이 아님. tutorial도 "MIG 81.25 / proc 200 / CDC by AXI Interconnect"로 확인.)
- `ui_clk` 산출: `TimePeriod=3077ps → DDR CK 325MHz`, `PHYRatio 4:1` → **ui_clk = 325/4 = 81.25MHz** (현 BD 설정값, `report_clocks`로 live 확인 권장).

### 1.4 이득도 0
- 워크로드가 가속기-bound(PS는 셋업·폴링만) → PS/AXI를 300으로 올려도 추론 속도 변화 없음. 전력만 증가.

### 결론
**가속기 datapath만 300MHz, 나머지(MicroBlaze/AXI/CSR/CDMA = 100, MIG = 81.25/200)는 유지, 경계에 작은 CDC.**

---

## 2. 클럭 아키텍처 (clk_wiz)

같은 MMCM(`clk_wiz_0`)에서 출력 → 100과 300이 **위상 정렬(3:1)**. 이 동기 위상정렬이 BMG Port A의 100→300 write 버스를 `set_multicycle_path`로 닫는 전제. *(MMCM·위상정렬·multicycle 개념을 모르면 → **부록 A** 먼저.)*

| 출력 | 주파수 | 용도 | 변경 |
|---|---|---|---|
| `clk_out1` | **100MHz** | MicroBlaze + 전 AXI + CSR + CDMA + 가속기 **`aclk`** | 유지(가속기 aclk로도 재사용) |
| `clk_out2` | **200MHz** | MIG `clk_ref_i`(IDELAYCTRL) | 유지(건드리지 않음) |
| **`clk_out3`** | **300MHz (신규)** | 가속기 **`clk`** 전용 | **추가** |

- 100/200/300은 한 MMCM에서 동시 출력 가능(예 VCO 600 → ÷6/÷3/÷2; clk_wiz GUI가 M/D 자동 산출).
- MIG(81.25)는 별도 도메인 유지(AXI converter가 처리).

---

## 3. CDC — 왜 RTL을 바꿔야 하나 + 무엇을 바꿨나

### 3.1 BD만으로는 불가능
BD(`connect_bd_net`)는 "선 잇기"라 **순차 로직(FF)을 만들 수 없음**. Vivado는 sideband 단일비트 신호에 동기화기를 자동 삽입하지 않음(AXI 채널만 인터커넥트가 처리). 따라서 제어 pulse의 CDC용 FF는 **반드시 RTL**에 들어가야 함 → cnn_accelerator 내부에 배치(CSR/firmware 무변경).

### 3.2 횡단 신호와 각각의 버그
| 신호 | 방향 | CDC 없으면 |
|---|---|---|
| `start`, `img_ready` | CSR 100 → datapath 300 | 1-cycle@100 펄스가 300에서 **3 cycle**로 보임 → conv1 handshake 카운터 **3배 차감(`prior_diff -=3`)** → 같은 image 3번 처리 + input bank desync |
| `img_done`, `input_consumed` | datapath 300 → CSR 100 | 1-cycle@300(3.33ns)을 100MHz가 **놓침** → `img_cnt` 미달(done 영원히 안 뜸) / `inflight` 안 줄어 `can_load` 데드락 |
| `enable` | CSR 100 → datapath 300 | level → 2-FF 동기화면 충분 |

### 3.3 해법
- `RTL/core/cdc_pulse_sync.v` — **toggle 기반 pulse 동기화기**(src toggle → dst 2-FF + edge 복원). 방향 무관. start/img_ready(100→300), img_done/input_consumed(300→100)에 사용.
- `RTL/core/cdc_bit_sync.v` — 2-FF level 동기화기. enable에 사용.
- 전부 **cnn_accelerator 내부**에 인스턴스화 → **CSR / firmware 완전 무변경**.
- (pulse 간격이 image당 1회 수준 = 수백 cycle 간격이라 toggle 동기화기로 안전.)

### 3.4 ★ Multi-bit CDC 안전성 감사 (핵심 검증)
> 단일비트 pulse는 동기화기로 충분하지만, **multi-bit(`img_cnt`, `result` 등)는 단순 2-FF가 위험**(비트별 resolve 시점이 달라 transient 값 latch). → 실제 신호를 전수 점검: **위험한 naive multi-bit 2-FF는 설계에 없음.**

| 신호 | 폭 | 횡단? | 처리 방식 (안전한 이유) |
|---|---|---|---|
| `enable/start/img_ready/img_done/input_consumed` | 1-bit | O | **CSR↔accel 경계는 전부 1-bit** → 동기화기로 커버 |
| `img_cnt`, `inflight`, `timer` | multi-bit | **X** | CSR(100) 도메인 전용. **동기화된 1-bit `img_done` 펄스로 100쪽에서 카운트 재구성** → multi-bit 값이 경계를 안 건넘 (정석 패턴) |
| `result`(4b) | multi-bit | O(300→100) | CSR에서 **제거됨**(phase-2). `bram_output` **dual-clock BRAM** 경유(Port A write@300 / Port B read@100). PS는 run 종료 후 정적 read → 충돌 없음. 2-FF 아님 |
| `in/c1w/c2w/fcw_dina·addra` | 32~512b | O(100→300) | **유일한 multi-bit 횡단.** 2-FF 안 씀 → **같은 MMCM 위상정렬 + `set_multicycle_path` + idempotent write**(같은 addr/data 3회 기록). ★실제 검증 포인트 |
| `res_rd_data`(32b) | multi-bit | **X** | `bram_output` Port B `clkb=aclk(100)`로 옮김 → AXI BRAM Ctrl(100)과 동일 도메인, 횡단 없음 |

핵심: multi-bit는 ① BRAM 경유(result), ② 카운터 재구성(img_cnt), ③ 위상정렬+multicycle(write 버스)로 처리. CSR 경계가 100% 1-bit인 게 안전성의 근간(phase-2가 result를 CSR에서 빼고 BRAM으로 보낸 덕).

---

## 4. BMG 클럭 경계 (regen 최소화)

| BMG | clka | clkb | 비고 |
|---|---|---|---|
| `bram_c1_to_c2` / `bram_c2_to_pool` / `bram_pool_to_fc` (inter-stage) | clk(300) | clk(300) | 양 포트 datapath 도메인 → **common-clock 유지, regen 불필요** |
| `bram_input`, `conv1/2/fc_weight_bram` (PS write) | clk(300) | clk(300) | Port A write 버스의 100→300 횡단은 IP 밖(boundary net)에서 발생 → **BMG는 common-clock 유지, regen 불필요**. 횡단은 §7 multicycle로 처리 |
| `bram_output` (result) | **clk(300)** write | **aclk(100)** read | **independent-clock IP**(이미 준비됨). clkb만 aclk로 분리. 내부 CDC는 IP 자체 XDC가 처리 |

→ **BMG regen 0**. (multicycle로 안 닫히면 fallback: 해당 PS-write BMG를 independent-clock으로 재생성 + 엔진에 aclk 결선.)

---

## 5. RTL 변경 목록 (Vivado 복붙 대상)

| 파일 | 변경 | 비고 |
|---|---|---|
| `RTL/core/cdc_pulse_sync.v` | **신규** | toggle pulse 동기화기 |
| `RTL/core/cdc_bit_sync.v` | **신규** | 2-FF level 동기화기 |
| `RTL/cnn_accelerator.v` | **수정** | ① `aclk` 포트 추가 ② 도메인별 reset(rst@300 재동기화 / rst_a@100) ③ enable/start/img_ready 동기화 → `*_q` ④ img_done/input_consumed 출력 CDC ⑤ `bram_output .clkb(clk)→(aclk)` |
| `RTL/control_status_register/*` | **무변경** | CSR pristine |
| 엔진/BMG/weight_loader | **무변경** | — |
| `TB/multi_img/tb_cnn_accelerator_multi.v`, `tb_system_axi_multi.v` | 수정 | `.aclk(clk)` 추가(단일클럭 회귀용) |

> 엔진(conv1/conv2/maxpool/fc)·weight BMG는 전부 `clk`만 사용 → **aclk threading 불필요**(common-clock 유지 덕).

---

## 6. Block Design 작업 절차 (`bd_DMA_base.tcl` 기준, 정밀)

대상 cell: `clk_wiz_0`, `cnn_accelerator_0`, `csr_axi_1`. 100MHz 시스템 네트 = `microblaze_0_Clk`(= `clk_wiz_0/clk_out1`).

1. **cnn_accelerator IP 재패키징** — `aclk` 포트가 추가된 RTL로 IP repackage(Package IP → 소스 갱신 → Re-Package). BD에서 `cnn_accelerator_0` 우클릭 → *Refresh/Upgrade IP* → 새 `aclk` 핀 노출 확인.
2. **`clk_wiz_0` 재구성** — *Output Clocks* 탭: `clk_out3` 활성화, **Requested 300.000 MHz**. `NUM_OUT_CLKS` 2→3. `clk_out1`(100)·`clk_out2`(200)·reset(ACTIVE_LOW)·locked는 그대로. (GUI가 VCO/M/D 자동 재계산 — 100/200/300 동시 출력 feasible.)
3. **`cnn_accelerator_0` 재배선:**
   - `clk` 핀을 `microblaze_0_Clk`(100) 네트에서 **분리** → `clk_wiz_0/clk_out3`(300)에 연결.
   - 새 `aclk` 핀 → `clk_wiz_0/clk_out1`(100, = 기존 `microblaze_0_Clk` 네트)에 연결.
   - `resetn`은 그대로 `rst_clk_wiz_0_100M/peripheral_aresetn`(100). (가속기가 내부에서 300 도메인으로 재동기화함 → 별도 300용 proc_sys_reset **불필요**.)
4. **그대로 두는 것:** 모든 AXI BRAM Ctrl(input/c1w/c2w/fcw/result)·CSR(`csr_axi_1`)·CDMA·인터커넥트·MIG = `microblaze_0_Clk`(100)/ui_clk(81.25) 유지. 주소맵 무변경.
5. **Validate → Generate Output Products → Bitstream.**
6. **Vitis 플랫폼 재생성** — ★Update Hardware Specification 말고 **새 `.xsa`로 플랫폼 프로젝트 재생성**(캐시 함정, `vitis-mainc-bringup` 참조). **firmware 무변경.**

---

## 7. XDC Timing 제약

*(`set_multicycle_path`가 왜·어떻게 동작하는지 → **부록 A.3**.)*

`clk_wiz`가 만든 generated clock 이름은 `report_clocks`로 확인 후 치환(예 `clk_out1_..._clk_wiz_0_0`=100, `clk_out3_..._clk_wiz_0_0`=300).

```tcl
# ── 100 → 300 (AXI BRAM Ctrl → BMG Port A write 버스 + 제어 pulse 첫 sync FF) ──
#    데이터가 100MHz 한 주기 동안 안정 → 300 기준 3 cycle 창으로 완화 (idempotent 3회 write).
set_multicycle_path -setup 3 -from [get_clocks <CLK100>] -to [get_clocks <CLK300>]
set_multicycle_path -hold  2 -from [get_clocks <CLK100>] -to [get_clocks <CLK300>]

# ── 300 → 100 (img_done / input_consumed toggle 동기화기) ──
#    toggle는 image당 1회로 quasi-static → 단일 cycle로도 자연 closure. 대칭 완화는 무해.
set_multicycle_path -setup 3 -from [get_clocks <CLK300>] -to [get_clocks <CLK100>]
set_multicycle_path -hold  2 -from [get_clocks <CLK300>] -to [get_clocks <CLK100>]
```

**주의**
- **`set_clock_groups -asynchronous`(100↔300) 금지** — multi-bit write 버스가 동기 위상정렬에 의존하므로 async 선언 시 버스가 false-path되어 데이터 무결성 보장 안 됨. 두 클럭은 **related(같은 MMCM)** 로 유지.
- 동기화기 FF에는 RTL에서 `(* ASYNC_REG="TRUE" *)` 부여됨(배치/메타 처리).
- `bram_output`의 내부 clka(300)↔clkb(100) 크로싱은 **independent-clock IP 자체 XDC**가 처리(우리가 제약 불필요).
- intra-300 datapath(3.33ns)가 진짜 closure 대상 — L=2 + 파이프라이닝이 이를 위함.

---

## 8. 검증 순서

1. **iverilog 단일클럭 회귀** (`aclk=clk`) — ✅ **완료**: `tb_cnn_accelerator_multi` 40/40(1798 cyc/img), `tb_system_axi_multi` 10/10. CDC 추가가 datapath 거동을 안 깸 확인.
2. **iverilog 듀얼클럭 CDC TB** (`tb_system_axi_multi_2clk`, 100/300 위상정렬 3:1) — ✅ **완료**: logit 10/10 bit-exact + bram_output 10/10 + **img_cnt 정확히 +1/image**(3배카운트 X) + **데드락 없음**(input_consumed 손실 X). triple-count/pulse-loss 기능 검증 통과.
3. **Vivado** — 합성 → §7 XDC → **WNS ≥ 0 @300MHz** 확인.
4. **HW** — N=100 → N=10000. **class match 10000/10000 유지 + timer(100MHz cycle) ~1/3 → wall-clock ~3× 단축**이면 성공.

---

## 9. 리스크 / 열린 항목
- ★ **BMG Port A 100→300 write 버스의 multicycle** — 가장 큰, 그리고 **유일하게 "지금" 확정 못 하는** 검증 포인트. sim은 **기능**(idempotent 3회 write → 데이터 정확)까지만 보여줌(2clk TB 통과). **실 타이밍(배선이 3틱 창 안에 도착? WNS≥0?)·메타스테이블은 Vivado P&R + HW로만 확정** (sim/검증 한계표 → **부록 A.4**). 안 닫히면 → 해당 BMG independent-clock regen + 엔진 aclk 결선(fallback).
- `clk_wiz` 300 추가 후 VCO/jitter 경고 확인(100/200/300 동시 — feasible하나 GUI 경고 점검).
- live BD의 MIG 설정(tCK 3077 / 4:1 → ui_clk 81.25)이 백업과 동일한지 `report_clocks`로 확인.

---

## 10. 클럭 도메인 & 경계 전수 (오버클럭 후)

### 10.1 클럭 도메인 (4개)
| 도메인 | 주파수 | 소속 블록 | 출처 |
|---|---|---|---|
| **300MHz** | `clk_out3` ★신규 | `cnn_accelerator.clk`: 전 engine(conv1/2·maxpool·fc) + inter-stage BMG(c1c2/c2pool/poolfc 양포트) + weight BMG(양포트) + `bram_input`(양포트) + `bram_output` **Port A(write)** | clk_wiz(같은 MMCM) |
| **100MHz** | `clk_out1` | MicroBlaze, perif/ram 인터커넥트(MIG측 제외), **CSR**, AXI BRAM Ctrl ×5, **CDMA**, UART, `cnn_accelerator.aclk`, `bram_output` **Port B(read)** | clk_wiz |
| **200MHz** | `clk_out2` | **MIG `clk_ref_i`(IDELAYCTRL)** — 로직 fabric 으로 나가지 않음 | clk_wiz |
| **81.25MHz** | MIG `ui_clk` | `ram_interconnect` **M00(MIG S_AXI측)만** | MIG 내부(DDR 325MHz÷4) |

### 10.2 도메인 경계 (CDC 지점)
| 경계 | 위치 | 신호 | 처리 메커니즘 | 신규? |
|---|---|---|---|---|
| **100 ↔ 81.25** | `ram_interconnect`(M00=MIG, S00/S01/S02/M01=100) | AXI 채널(MB I$/D$, CDMA ↔ DDR) | **AXI Interconnect 내장 clock converter**(async FIFO) — 자동 | 기존 |
| **100 → 300** (제어 pulse) | CSR ↔ cnn_accelerator | `start`/`img_ready`(100→300), `img_done`/`input_consumed`(300→100), `enable`(level) | **cnn_accelerator 내부** `cdc_pulse_sync`(toggle) + `cdc_bit_sync` | ★RTL |
| **100 → 300** (write 버스) | AXI BRAM Ctrl → BMG Port A | `in`/`c1w`/`c2w`/`fcw` 의 en·we·addr·din (multi-bit) | 같은 MMCM **위상정렬 + `set_multicycle_path` + idempotent write** (동기화기 아님) | ★XDC |
| **300 ↔ 100** (result) | `bram_output` 내부 | Port A write@300 / Port B read@100 | **independent-clock BRAM**(IP 자체 CDC); fabric 양측은 각 단일도메인 | ★IP설정 |
| 200 | (MIG 내부) | IDELAYCTRL ref | fabric 횡단 없음 | 기존 |

> **직접 300↔81.25 경계는 없음.** 가속기(300)는 MIG(81.25)와 직접 통신 안 함 — 데이터는 항상 100을 거쳐 두 홉으로 전달.

### 10.3 데이터 흐름 + 횡단 지점
```
 DDR3 (81.25, MIG ui_clk)
   │  ⟨AXI Interconnect CDC : 81.25 ↔ 100⟩            ← 기존(자동)
   ▼
 MicroBlaze / CDMA / AXI BRAM Ctrl / CSR   (100, clk_out1)
   │  ⟨100→300 : 위상정렬 + multicycle + idempotent⟩   ← ★신규(write 버스)
   ▼
 bram_input → conv1 → c1c2 → conv2 → c2pool → maxpool → poolfc → fc   (전부 300, clk_out3)
   ▲                                                              │
   │  ⟨CSR(100) ⇄ cdc_pulse_sync/bit_sync ⇄ engine(300)⟩          │  ← ★신규(제어 pulse)
   │     start·img_ready·enable (100→300) / img_done·input_consumed (300→100)
   │                                                              ▼
 bram_output :  write @300  │ ⟨dual-clock BRAM⟩ │  read @100  → AXI BRAM Ctrl(100) → PS   ← ★신규(result)
```
- ★ 표시 3개가 이번 작업이 새로 만든 경계. 나머지(100↔81.25)는 기존부터 AXI Interconnect 가 처리하던 것.

---

## 부록 A — 핵심 개념 해설 (MMCM / 위상정렬 / set_multicycle_path / sim의 한계)

> §2·§7·§9를 처음 보는 사람을 위한 배경. 이미 아는 용어면 건너뛰어도 됨.

### A.1 MMCM (Mixed-Mode Clock Manager)
FPGA 내부 **클럭 생성기 하드웨어**. `clk_wiz` IP가 이 MMCM을 감싼 것. 입력 클럭 1개 → 여러 주파수 클럭을 **동시에** 생성:
```
입력(100MHz) ─÷D─×M─▶ VCO(고주파, 예 600MHz) ─┬─ ÷6 → 100MHz (clk_out1)
                                               ├─ ÷3 → 200MHz (clk_out2)
                                               └─ ÷2 → 300MHz (clk_out3)
```
- `VCO = 입력 × M / D`, 각 출력 `= VCO / 분주값`. (M/D/분주는 clk_wiz GUI 가 자동 산출.)
- **모든 출력이 같은 VCO·피드백에서 정렬** → 서로 주파수 잠금 + 위상 정렬. → 100/200/300 을 **한 MMCM** 에서 뽑는 이유(§2).
- "Mixed-Mode" = PLL(주파수 합성·지터 제거) + DCM(위상 이동) 겸용.

### A.2 위상 정렬 (phase-aligned)
두 클럭의 rising edge 가 **같은 시각에(고정 관계로) 뜨는** 상태. 비동기면 엣지가 제멋대로 드리프트한다.
```
100MHz: ‾‾‾‾‾‾‾‾|________|‾‾‾‾‾‾‾‾|     엣지 @ 0, 10, 20 ns
300MHz: ‾‾|__|‾‾|__|‾‾|__|‾‾|__|‾‾      엣지 @ 0, 3.33, 6.67, 10 ...
        ▲           ▲   ← 100 의 매 엣지마다 300 엣지 하나가 정확히 겹침 (drift 0)
```
- 같은 MMCM 출력이라 100 엣지마다 300 엣지가 일치(3배 → 3개 중 1개 겹침).
- **왜 중요**: 100→300 타이밍 관계가 **결정적** → (A.3) multicycle 을 쓸 수 있고 "데이터가 100 한 주기 안정" 논리가 성립 → **BMG regen 없이** 감. 비동기였다면 independent-clock regen 필요.
- sim 에선 `clk100` half=5.001 / `clk300` half=1.667 (3×1.667=5.001), 둘 다 0 출발 → 영원히 정렬(드리프트 0)으로 모사.

### A.3 set_multicycle_path
STA(타이밍 분석기)에게 **"이 경로는 1 클럭 말고 N 클럭 줘도 된다"** 알리는 XDC 제약.
- **기본 가정**: FF→FF 는 1 목적지 클럭 주기 안에 도착해야 함.
- **문제**: 100→300 은 위상정렬이라 launch 직후 **그 순간(0ns) 300 엣지가 겹침** → "0ns 안에 도착하라" → 불가 → 가짜 음수 slack.
- **현실**: 100 이 쏜 데이터는 **100 한 주기(10ns = 300 기준 3틱)** 동안 안 변함 → 3번째 엣지에 잡아도 됨.
- **`set_multicycle_path -setup 3` (+ `-hold 2`)** → setup 을 3번째 300 엣지에 검사 → 요구시간 ~10ns 로 완화 → 쉽게 닫힘.
- 비유: 기본 "문제당 1초" → multicycle "이 문제는 데이터가 3초마다 바뀌니 3초 줄게".
- ⚠️ 그래서 `set_clock_groups -asynchronous`(100↔300) 금지 — async 로 풀면 이 버스가 false-path 돼 무결성 보장이 사라짐(§7).

### A.4 sim 이 검증하는 것 vs 못 하는 것 (왜 §2 write 버스는 "지금" 확정 못 하나)
| 항목 | iverilog sim | Vivado timing(STA) | HW |
|---|---|---|---|
| 제어 pulse CDC(③) **논리** — 3배카운트/손실/데드락 | ✅ 검증됨(2clk TB) | — | 확인 |
| write 버스(②) **기능** — idempotent 3회 write→데이터 정확 | ✅ 모사·통과 | — | 확인 |
| write 버스(②) **실 타이밍** — 배선지연이 3틱 창 안? | ❌ (이상화) | ✅ **WNS 로만 확정** | 확인 |
| 메타스테이블 | ❌ (결정적이라 모델 안 됨) | (제약·구조로 관리) | 확인 |

- sim 은 **기능/논리**만 본다(이상적 엣지, 배선지연·메타 없음). ②의 idempotent write 가 "동작한다"까진 보여줬지만, **그 배선이 실제로 3틱 안에 도착하는지(WNS≥0)는 Vivado P&R + 보드로만** 알 수 있음 → **②가 유일하게 "지금 모르는" 부분**.
- 반면 ③(제어 pulse)은 동기화기 **논리**를 sim 이 직접 통과시켰고, 2-FF 는 메타 내성이 검증된 표준 → sim+구조로 충분.

---

## 11. Sources (전체 오버클럭 불가 근거)
- [MicroBlaze Maximum Frequencies — UG984 (AMD)](https://docs.amd.com/r/en-US/ug984-vivado-microblaze-ref/Maximum-Frequencies)
- [MicroBlaze-DDR3-tutorial — viktor-nikolov (Arty A7, 거의 동일 셋업; 200MHz timing fail / 100MHz 안전)](https://github.com/viktor-nikolov/MicroBlaze-DDR3-tutorial)
- [ARTY MicroBlaze Running at 100MHz — Digilent Forum](https://forum.digilent.com/topic/1993-arty-microblaze-running-at-100mhz/)
- [AXI SmartConnect Performance/Fmax (AMD)](https://download.amd.com/docnav/documents/ip_attachments/smartconnect.html)
- [AXI Interconnect v2.1 — PG059 (AMD)](https://docs.amd.com/r/en-US/pg059-axi-interconnect)

---
*관련: `docs/ip_spec/block_memory_generator.md`(BMG L=2/REGCEB), `docs/conv1_timing.md`, `RTL/conv2/conv2_timing.md`, memory `overclock-300mhz-kickoff`.*
