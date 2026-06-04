# 300MHz Overclock — 설계 / 구현 노트

CNN Accelerator(Arty A7-100T, `xc7a100t-csg324-1`, speed grade **−1**)의 PL datapath를
**100MHz → 300MHz** 로 올려 latency를 ~3× 단축하는 작업의 설계 결정·구현·BD 절차·검증 정리.

- **현황(committed `4c5dedb` @dohyun):** N=10000 **0.188s, class match 10000/10000 @100MHz**. 누적 5.8×(DMA까지). **가속기-bound**(conv2 throughput floor ~1798 cyc/img).
- **목표:** 가속기 datapath만 300MHz → wall-clock ~3× 단축(~0.063s 기대). **firmware 무변경**(cycle 거동 동일, timer가 세는 100MHz cycle 수가 ~1/3로 줄어 wall-clock 단축).
- **데이터패스 300MHz prep는 이미 완료**(BMG L=2 + 파이프라이닝, iverilog 검증). 이번 작업은 **클럭 분리 + 클럭도메인횡단(CDC) + timing 제약**.

> ### ⚠️ 2026-06-04 목표 전환: 300MHz → **190MHz (1.9×)**
> N=1(Step1b+Step2) 빌드에서 conv2 broadcast 는 닫혔으나(워스트에서 사라짐), reset fanout(fo=41323, −1.94) + FSM/handshake 잔여(−1.7)가 die 전역에 분포(DSP 94%, floorplan 불가). 실효 최대주파수 ≈ **~190MHz**(binding=reset 5.276ns→189.6MHz). 300(3.33ns) closure 는 비현실적 → **190MHz 타협 확정**(여기까지가 MHz ROI 최대 구간; 그 다음 best 레버 = **Winograd**, §13.5). 상세 §13. (§1~§12 의 CDC/BD/XDC 골격 유효 — 단 190 은 100 과 **1.9:1 비정수**라 write-bus 제약을 multicycle→`set_max_delay -datapath_only`로 변경, §13.4.)

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
| `RTL/conv2/conv2_engine.v` | **수정** | ★timing closure(§11.6): Step 1b(weight broadcast +1 reg) + Step 2(`PE_BC_DELAY` PE 입력 +N reg 복제 + downstream 재타이밍). iverilog bit-exact. |
| `RTL/conv2/conv2_fsm.v` | **수정** | ★timing closure(§11/§11.6): `(* max_fanout=32 *)` on `state`/`kw_cnt`(복제) + `PE_BC_DELAY` 파라미터로 DRAIN 을 `11+N` 연장. 논리 불변 |
| `RTL/conv2/weight_loader.v` | **수정** | ★timing closure(§11): `(* max_fanout=32 *)` on `pe_id`, `slot_id`, `pe_load_en`. 논리 불변 |
| conv1/maxpool/fc 엔진·BMG | **무변경** | — |
| `TB/multi_img/tb_system_axi_multi_2clk.v` | **신규** | 듀얼클럭 CDC 검증 TB(§8.2) |
| `TB/multi_img/tb_cnn_accelerator_multi.v`, `tb_system_axi_multi.v` | 수정 | `.aclk(clk)` 추가(단일클럭 회귀용) |

> 엔진·weight BMG는 전부 `clk`만 사용 → **aclk threading 불필요**(common-clock 유지 덕). conv2 max_fanout 은 **속성만**(기능 불변, 재타이밍 아님 — §11.3 Step 1).

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

실제 적용 위치: **`Arty-a7-100-Master_v2.xdc`** 끝에 append됨(`v1`=원본 백업). `report_clocks`로 확인한 이 프로젝트의 실제 클럭 이름:
`clk_out1_cnn_accelerator_system_clk_wiz_0_0`=100MHz, `clk_out3_cnn_accelerator_system_clk_wiz_0_0`=300MHz (clk_out2=200 MIG ref).

```tcl
set CLK100 [get_clocks clk_out1_cnn_accelerator_system_clk_wiz_0_0]
set CLK300 [get_clocks clk_out3_cnn_accelerator_system_clk_wiz_0_0]

# ── 100 → 300 (slow→fast): AXI BRAM Ctrl → BMG Port A write 버스(multi-bit) ──
#    데이터가 100MHz 한 주기(=300 기준 3 cycle) 안정 → setup 을 3번째 300 엣지로 완화
#    (idempotent 3회 write). enable/start/img_ready 동기화기 첫 FF(quasi-static)도 함께 완화.
set_multicycle_path -setup 3 -from $CLK100 -to $CLK300
set_multicycle_path -hold  2 -from $CLK100 -to $CLK300

# ── 300 → 100 (fast→slow): 이 방향 fabric 경로는 img_done/input_consumed 의 ──
#    toggle 동기화기(2-FF) 입력뿐 → CDC false_path. (메타는 2-FF+ASYNC_REG 흡수;
#    multicycle 아님 — fast→slow coincident-edge hold 위험을 회피.)
set_false_path -from $CLK300 -to $CLK100
```

**주의**
- **100→300 은 `set_multicycle_path`, 300→100 은 `set_false_path`** — 비대칭. 이유: 100→300 cone 엔 write 버스(실데이터, 타이밍 필요)가 있어 multicycle, 300→100 cone 엔 동기화기 입력만 있어 CDC(false_path). 300→100 에 multicycle(특히 fast→slow hold) 거는 건 불필요·위험.
- **`set_clock_groups -asynchronous`(100↔300) 금지** — multi-bit write 버스가 동기 위상정렬에 의존하므로 async 선언 시 버스가 false-path되어 데이터 무결성 보장 안 됨. 두 클럭은 **related(같은 MMCM)** 로 유지.
- 동기화기 FF에는 RTL에서 `(* ASYNC_REG="TRUE" *)` 부여됨(배치/메타 처리). (더 타이트한 MTBF 원하면 false_path 대신 `set_max_delay -datapath_only` 로 동기화기 입력 net 을 bound 가능.)
- `bram_output`의 내부 clka(300)↔clkb(100) 크로싱은 **independent-clock IP 자체 XDC**가 처리(우리가 제약 불필요).
- intra-300 datapath(3.33ns)가 진짜 closure 대상 — L=2 + 파이프라이닝이 이를 위함.

---

## 8. 검증 순서

1. **iverilog 단일클럭 회귀** (`aclk=clk`) — ✅ **완료**: `tb_cnn_accelerator_multi` 40/40(1798 cyc/img), `tb_system_axi_multi` 10/10. CDC 추가가 datapath 거동을 안 깸 확인.
2. **iverilog 듀얼클럭 CDC TB** (`tb_system_axi_multi_2clk`, 100/300 위상정렬 3:1) — ✅ **완료**: logit 10/10 bit-exact + bram_output 10/10 + **img_cnt 정확히 +1/image**(3배카운트 X) + **데드락 없음**(input_consumed 손실 X). triple-count/pulse-loss 기능 검증 통과.
3. **Vivado** — 합성 → §7 XDC → WNS ≥ 0 @300MHz. ⚠️ **1차 결과: timing FAIL(WNS −2.99)** — CDC/제약은 검증됐고(§11.1) **conv2 broadcast fanout 이 병목**(§11.2). closure 작업 진행중(§11.3 Step 1: replication+phys_opt). **→ §11 로그 참조.**
4. **HW** — N=100 → N=10000. **class match 10000/10000 유지 + timer(100MHz cycle) ~1/3 → wall-clock ~3× 단축**이면 성공. (timing closure 후)

---

## 9. 리스크 / 열린 항목
- ✅ **(해소) BMG Port A 100→300 write 버스 multicycle** — 1차 구현에서 **+0.107ns clean**(req 10ns), idempotent write 검증됨. 예측했던 최대 리스크였으나 의도대로 작동(§11.1). CDC 메타는 2-FF+ASYNC_REG 로 처리.
- ★ **(현 주리스크) conv2 broadcast fanout 의 300MHz closure** — datapath 실효 Fmax ≈158~165MHz, route 지배. Step 1(replication+phys_opt)로 얼마나 좁혀지는지가 관건. 안 되면 Step 2(제어 broadcast 파이프라인, 침습적·재검증). **→ §11.**
- `clk_wiz` 300 추가 후 VCO/jitter 경고 확인(100/200/300 동시 — feasible하나 GUI 경고 점검).
- live BD의 MIG 설정(tCK 3077 / 4:1 → ui_clk 81.25)이 백업과 동일한지 `report_clocks`로 확인.
- (부차) clk_out1(100) 도메인 ram_interconnect 512b up/downsizer −0.043ns/8ep — 300 이슈와 별개, impl strategy 로 정리 가능.

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

## 11. 300MHz Timing Closure 로그 (구현 1차 + conv2 broadcast fanout)

### 11.1 구현 1차 결과 (@300MHz, phys_opt 전)
write_bitstream 은 완료됐으나 **timing FAIL**: **WNS −2.99ns, TNS −153865ns, Failing Endpoints 110302/176215**.

`report_clock_interaction` 판독 — **CDC/제약은 전부 검증됨(무죄)**, 실패는 100% datapath 내부:
| From → To | WNS | Failing | 분류 |
|---|---|---|---|
| **clk_out3 → clk_out3** (300 datapath) | **−2.99** | **110302** | ★ 전부 여기 |
| clk_out1 → clk_out3 (write 버스) | **+0.107** | 0 | multicycle 작동(req=10ns) ✅ |
| clk_out3 → clk_out1 (toggle) | — | — | false_path 작동 ✅ |
| clk_out1 → clk_out1 (100 도메인) | −0.043 | 8 | ram_interconnect 512b up/downsizer, 별개·미세 |

### 11.2 진단 — 병목은 compute 아닌 conv2 broadcast (route 지배)
워스트 경로(`report_design_analysis` / `report_timing`, 저장: `docs/timing/overclock_timing_violation_except_conv2weight.txt`):
- `conv2/wl_inst/pe_id` → (LUT decode) → PE `w_regs_reg/CE`. **Path 6.10ns = logic 0.83(14%) + route 5.28(86%)**, Logic Levels 3, **DSP None**.
- = **weight-load enable broadcast** (MAC 아님). `pe_cell` 확인: `w_regs CE=load_en`(1회성 적재 전용), compute는 `w_regs[sel]→DSP` 풀파이프(AREG/BREG/MREG/PREG)로 **분리**.
- ★ **weight-load 제외**(`set_false_path -to *w_regs_reg*`) 후 재측정 → **여전히 WNS −2.72, 67206 failing**. 새 워스트 `conv2/fsm_inst/state → DSP`, 또 route 86%.
- **결론**: weight-load 는 워스트일 뿐, 실패는 **conv2 제어/weight/activation broadcast 전반**(`state`/`sel`/`pe_en`/`pe_id`/`packed_w` → die 전역 분산 **192개 PE**, fanout=192). **로직 깊이 문제 아님(logic 14%) — fanout+placement+congestion 의 route 지배**. datapath 실효 Fmax ≈ **158~165MHz** @300타겟.

### 11.3 Fix 전략 (escalation — 덜 침습적 우선)
| Step | 내용 | 리스크 | 상태 |
|---|---|---|---|
| **1** | **replication**: `max_fanout=32` on conv2_fsm `state`/`kw_cnt`, weight_loader `pe_id`/`slot_id`/`pe_load_en` + impl **`phys_opt_design -directive AggressiveFanoutOpt`** | 무위험(논리 불변, 40/40 유지) | **적용·측정중** |
| **1b** | **packed_w 복제 register** (+1 cycle, weight-load 1회성이라 무해) — `w_regs/D`(fo=192)가 새 워스트면 | 낮음(iverilog 재검증) | 대기 |
| **2** | **제어 broadcast 파이프라인 + 재타이밍** — conv2 제어 register 단 추가 + 컴퓨트 정렬 재조정 | 높음(conv2 가장 복잡, iverilog 재검증 필수) | 측정 후 결정 |

**측정 결정점**: WNS≥0 → 닫힘 / 살짝 음수 → 1b·floorplan / −2 근처(FSM 제어) → Step 2.

### 11.4 핵심 교훈
- **L=2 BMG prep(BRAM read)로는 부족** — compute는 DSP 풀파이프로 OK지만, **고fanout 제어/weight broadcast가 route 지배**로 300MHz 진짜 병목. iverilog는 타이밍을 안 보니(부록 A.4) 이건 Vivado에서만 드러남.
- **CDC·XDC 설계는 1차 구현에서 완전 검증**(multicycle/false_path 의도대로). 남은 건 순수 conv2 물리 closure.

---

### 11.5 Step 2 상세 계획 (핸드오프 — conv2 broadcast 파이프라인)
**Step 1 결과**: max_fanout+phys_opt → WNS −2.99→**−2.454**(TNS 절반, Failed Routes 0, WHS +0.051). ~173MHz. 복제만으론 부족 — **DSP 226/240=94%** 라 PE가 die 전역 DSP 컬럼에 깔려 broadcast 가 본질적으로 die-spanning(floorplan 불가). **파이프라인이 유일 레버.**

**선행(쉬움) — Step 1b: weight broadcast 복제 register.**
conv2_engine 에서 `wl_packed_w`/`wl_slot_id`/`pe_load_en_dec` 를 +1 register(`(* max_fanout *)`), PE 는 `_r` 버전 사용. **weight-load 1회성**이라 +1 무해(loader_done→compute 시작까지 수천 cycle 여유). packed_w(fo=192) 복제로 weight-load 워스트 제거. iverilog 40/40 확인.

**본체 — Step 2: PE 입력단 register stage (+N, 재타이밍).**
- conv2_engine PE-array fan-in 을 +N register(복제): `pe_x`(col_sel mux 출력), `fsm_sel`, `fsm_pe_en`. **col_sel·shift_en·FSM 카운터·c1c2 read 는 원래 타이밍 유지**(window/mux 그대로, mux 출력 pe_x 만 register).
- downstream 정렬: `sel_pipe`/`pe_en_pipe`/`adder_en`/`kcol_en`/`kcol_kw_phase` 를 **지연된 sel/pe_en 에서 tap** → 전체 +N 균일 시프트(상대 정렬 보존).
- ★ 재타이밍 검증점: `c2pool_we_reg`/`write_addr` 및 `rdone`/`wdone`(conv2_engine §14). rdone=conv1-facing(c1c2 read 미지연→불변), wdone=maxpool-facing(write +N→지연, race-free 핸드셰이크라 무해 예상) — **반드시 iverilog 확인**.
- N=1 부터 → Vivado WNS 보고 부족하면 N=2.

**검증**: iverilog `tb_conv1_conv2_multi`(40/40, 0/23040) + `tb_cnn_accelerator_multi`(40/40) **bit-exact 유지**(latency +N 늘지만 logit 동일) → Vivado 재구현 @300 → WNS 반복.
**병행/대안**: max_fanout 16/8, impl `Performance_Explore`, post-route phys_opt. 그래도 ~−1.5ns 벽이면 **200MHz(2×) 타협** 검토.

**다음 에이전트가 먼저 받을 것**: Step 1 후 `report_design_analysis -setup -max_paths 10` 의 새 워스트 경로(weight-load면 1b, FSM 제어면 Step2 본체).

---

### 11.6 Step 1b + Step 2 구현 완료 (2026-06-04, iverilog bit-exact 검증, Vivado 대기)

두 워스트(weight-load broadcast / compute-control broadcast)가 **둘 다** 닫혀야 하므로 (Step 1 replication 후 둘 다 −2.454 잔존), **Step 1b 와 Step 2 를 함께 구현**. 파일: `RTL/conv2/conv2_engine.v`, `RTL/conv2/conv2_fsm.v`. (weight_loader.v 는 Step 1 의 `max_fanout` 만, 변경 없음.)

| | 무엇 | 어디 | 효과 |
|---|---|---|---|
| **Step 1b** (always-on) | weight broadcast `pe_load_en_dec`/`packed_w`/`slot_id` → **+1 register** (`pe_load_en_dec_r`/`wl_packed_w_r`/`wl_slot_id_r`, 후2개 `max_fanout=32`), PE 가 `_r` 사용 | conv2_engine §5.5, §8 | die-spanning weight-load route 를 2단 분할. load 1회성이라 +1 cycle compute 무영향 |
| **Step 2** (param `PE_BC_DELAY`, 기본 1) | `fsm_sel`/`fsm_pe_en`/`pe_x`(mux 출력) → **+N register 복제** (`sel_sr`/`pe_en_sr` `max_fanout=32`), PE 가 `pe_sel_bc`/`pe_en_bc`/`pe_x_d` 사용. `sel_pipe[0]`/`pe_en_pipe[0]` 를 지연 버전에서 tap → downstream 전체 +N 균일 시프트 | conv2_engine §7.5, §9 | compute-control/activation broadcast route 를 PE 클러스터 근처 replica 출발로 단축 |
| **Step 2 (FSM)** | `DRAIN_LAST = 11 + PE_BC_DELAY` (drain_cnt 종료 3곳) | conv2_fsm §1,5,6,6.5 | datapath +N drain 보존 → 마지막 c2pool write 가 write_addr/output_pixel_cnt reset 전 완료 |

- **N 변경법**: `conv2_engine.v` 의 `parameter PE_BC_DELAY = 1` 한 줄만 수정(0=Step2 off·Step1b만 / 1 / 2). conv2_engine 이 conv2_fsm 으로 자동 전달 → DRAIN 동기 연장. cnn_accelerator.v(top) 무변경(기본값 사용).
- **iverilog 검증 (bit-exact, N=0/1/2 전부)**:
  - 전체 파이프라인 `tb_cnn_accelerator_multi`: **40/40 logit + bram_output readback PASS**. cyc/img: N=0→1798(=baseline), N=1→1799, N=2→1800 (정확히 +N/img).
  - conv2-direct c2pool 비교: **40/40, 0/23040 bit-exact** (N=0/1 확인). wdone cycle 만 +N 시프트, 데이터 동일.
  - N=0 은 baseline 과 **cycle 까지 동일** → Step 1b 가 compute 에 무영향임을 실증. N≥1 의 +N/img 는 DRAIN 연장 그대로.
- ★ **검증 인프라 주의 (다음 작업자 필독)**: `tb_conv1_conv2_multi.v` 와 `tb_conv2_engine_multi.v` 는 **Mac 로컬에서 그대로 쓰면 안 됨**.
  - `tb_conv1_conv2_multi.v`: golden 경로가 Windows 절대경로 only (`C:/...`) → Mac 에서 `$readmemh` 전부 실패(전 X). 게다가 compare loop 이 **c2pool L=1 read** 가정인데 실제 BMG 는 **L=2** → off-by-one. 두 가지(경로→`data/` + read `i-1`→`i-2`, loop 577→578) 패치해야 동작. (로컬 테스트용 패치본은 commit 안 함.)
  - `tb_conv2_engine_multi.v`: Mac 에서 **hang** (무한 대기).
  - `tb_conv1_conv2_maxpool_fc_multi.v`: FC weight **512b 변경 미반영**(port width 32/256 경고) → stale, 0/40.
  - → **로컬 신뢰 gate = `tb_cnn_accelerator_multi` (local `data/` 경로·L=2 정합·40/40)**. Vivado/Windows 머신에서는 위 TB 들이 정상일 수 있음.
- **adversarial 감사 (5-lens, 2026-06-04)**: retiming 정렬 불변식 / Step1b weight-load 안전성 / DRAIN·write_addr·wdone 타이밍 / missed-consumers = **전부 CORRECT**. Vivado-synth lens 의 blocker(“max_fanout on unpacked array 가 intermediate stage 복제 안 함”)는 adversarial verify 가 **반증**(N=1 기본 config 엔 intermediate stage 없음 — fanout 은 단일 출력 reg 에 있고 attribute 적용됨; 게다가 phys_opt `AggressiveFanoutOpt` 가 복제 보장). 실제 반영한 개선: `drain_cnt` 4→**5-bit**(N>4 overflow footgun 제거, N≤20 safe) + stale 주석 정정.
- **다음(Vivado)**: ① N=1 로 합성/구현 → `report_design_analysis -setup -max_paths 10` + `report_clock_interaction`. ② WNS≥0 → 닫힘(HW 검증으로). 살짝 음수 → `PE_BC_DELAY=2` 로 한 줄 바꿔 재시도(iverilog 이미 bit-exact). ③ 여전히 weight-load(`*w_regs*/CE`) 가 워스트면 Step1b 가 안 먹은 것(복제/배치 점검), FSM-control(`fsm_inst/...`→DSP)이면 Step2 N 증가. ④ phys_opt `AggressiveFanoutOpt`(post-route 포함) 병행. ⑤ ~−1.5ns 벽이면 200MHz(2×) 타협.

---

## 12. Sources (전체 오버클럭 불가 근거)
- [MicroBlaze Maximum Frequencies — UG984 (AMD)](https://docs.amd.com/r/en-US/ug984-vivado-microblaze-ref/Maximum-Frequencies)
- [MicroBlaze-DDR3-tutorial — viktor-nikolov (Arty A7, 거의 동일 셋업; 200MHz timing fail / 100MHz 안전)](https://github.com/viktor-nikolov/MicroBlaze-DDR3-tutorial)
- [ARTY MicroBlaze Running at 100MHz — Digilent Forum](https://forum.digilent.com/topic/1993-arty-microblaze-running-at-100mhz/)
- [AXI SmartConnect Performance/Fmax (AMD)](https://download.amd.com/docnav/documents/ip_attachments/smartconnect.html)
- [AXI Interconnect v2.1 — PG059 (AMD)](https://docs.amd.com/r/en-US/pg059-axi-interconnect)

---

## 13. 200MHz(2×) 전환 — 결정 기록 + 근거 분석 (2026-06-04)

### 13.1 결정 (사용자, 2026-06-04)
**300MHz 목표를 190MHz로 전환.** 근거: Step1b+Step2(broadcast 파이프라인) 후에도 reset/FSM/handshake 가 die 전역에 −1.7~−1.94ns 로 분포해 실효 Fmax ≈ **189.6MHz**(binding = reset 5.276ns). 300(3.33ns) closure 는 다전선 die-spanning 경로를 전부 내려야 해 비현실적 — **여기까지가 MHz 의 ROI 최대 구간**, 그 위는 diminishing returns. 190MHz 도 conv2 throughput floor(1799 cyc/img) 기준 **0.188s → ~0.099s (1.9×, 누적 ~11×)**, firmware 무변경.
- **190 vs 188**: reset 경로 5.276ns → 190MHz(5.263ns)에선 **−0.013** (phys_opt 로 긁어야 닫힘), **188MHz(5.319ns)면 +0.043 으로 깔끔**. 성능차 1MHz(무시가능) → 마진 원하면 188 권장. FC/handshake(−1.715, 5.048ns)는 양쪽 다 +0.2 여유로 통과 → reset 만 binding.
- **다음 best 레버 = Winograd** (MHz 아닌 알고리즘 복잡도 ↓ — conv2 1799 cyc/img 가 throughput floor). §13.5.

### 13.2 N=1 (Step1b+Step2) Vivado 결과 + 진단 (routed, 2026-06-04)
WNS 추이: 1차 −2.99 → Step1(max_fanout+phys_opt) −2.454 → **Step1b+Step2 N=1 −2.187** (WHS +0.052, WPWS +0.206; setup 만 실패). **conv2 PE broadcast(sel/pe_en/x→192 PE)는 워스트 top15 에서 사라짐 = Step1b/Step2 성공.** 새 워스트는 전혀 다른 곳:

`report_design_analysis -setup -max_paths 15` 워스트:
- **#1,2,4 (−2.187): weight_loader 주소연산** `ic_cnt→…CARRY4×4…→c2w_addrb_reg[9]/D`. nested-multiply `(((oc*8)+ic)*3+kh)*3+kw` 가 6-level CARRY4(logic 3.08ns/56%). → **수정완료**(§13.3).
- **#3,5~15 (−1.94~−1.74): reset net** `rst_sync_reg→BUFG→(fo=41323)→DSP/RSTB·register`. route 85%.

weight_loader 제외(=고친 후) 잔여 분류 (top1500 violating sample):
| 분류 | count | worst |
|---|---|---|
| weight_loader (제외) | 5 | −2.187 |
| **reset-net** (`rst_sync` 출발) | **1343** | **−1.943** |
| **OTHER** (reset·wl 아님) | **152** | **−1.715** |

OTHER 는 단일이 아닌 **다종 −1.6~−1.7 덩어리**: FC FSM(`pair_cnt/s_cnt→state·fcw BMG addr` −1.72/−1.67), conv2 `state→pe_x_sr`(col_sel mux→Step2 reg 입력 −1.68), conv2 `sel_sr_rep→DSP/A`(Step2 broadcast 잔여, 복제됨 −1.60), conv2 `rdone→conv1 fsm CE`(핸드셰이크 −1.59).

**실효 Fmax 산수** (path delay = 3.333 − slack): wl 5.52 / reset 5.28 / OTHER 5.05ns. fix 누적 시 천장 = wl고침→reset(190MHz)→OTHER(198MHz)→다음 tier(~200–208MHz). → **~200MHz 벽** 확정. 이게 §11.5 가 예고한 "−1.5ns 벽".

### 13.3 적용한 RTL 수정
- **weight_loader 주소연산 → increment accumulator** (`RTL/conv2/weight_loader.v` §4.5): addr/pe_id 는 LOADING 중 0→575/0→191 단조증가만 하므로 nested-multiply 제거하고 `addr_seq`/`pe_id_seq` accumulator(+1)로 대체. 조합깊이 6→1. nested 카운터는 is_last_addr 전용 유지. **iverilog bit-exact 확인**(tb_cnn_accelerator_multi 40/40, conv2-direct 40/40 0/23040; addr/pe_id 시퀀스 동일). 1회성 로딩이라 거동 영향 0.
- Step1b/Step2(`PE_BC_DELAY=1`)는 200MHz 에서도 유지(bit-exact, +1cyc/img, 마진 도움).

### 13.4 190MHz closure 작업 (Vivado)
1. **clk_wiz**: `clk_out3` Requested **300→190 MHz** (마진 원하면 188). clk_out1=100, clk_out2=200 MIG ref 유지. 출력 port 명 불변 → 클럭 이름·XDC get_clocks 그대로.
2. **XDC** (`Arty-a7-100-Master_v2.xdc`): 190 은 100 과 **1.9:1 비정수** → write-bus 를 multicycle 대신 **`set_max_delay -datapath_only 10.000 -from $CLK100 -to $CLK_ACC`** (데이터패스 ≤ 1 slow period, 비율 무관, idempotent+stable 라 안전, -datapath_only 가 hold 자동 충족). false_path(accel→100) 유지. **적용완료.** (※ 200(2:1) 로 갈 거면 multicycle -setup 2 -hold 1 로 회귀.)
3. **RTL**: weight_loader fix(§13.3) + Step1b/Step2(`PE_BC_DELAY=1`) 복붙. (190 에서 weight_loader 미수정 시 5.52ns→−0.26 fail 이므로 fix 필수.)
4. **impl 전략**: `Performance_Explore`(또는 ExtraTimingOpt) + post-route `phys_opt_design`. 190 에서 binding 은 reset −0.013 뿐 → 전략/phys_opt 로 닫힐 듯(안 되면 clk 188 로). **route 지배라 진짜 판정은 post-route(impl) — synth-only timing 은 낙관적, 신뢰 말 것.**
5. **(불필요 예상이나 fallback) reset fanout 경감**: 만약 reset 이 phys_opt 로도 안 닫히면 — CDC(생성부) 불변, `pe_cell` DSP RSTA/B/M/P 등 datapath self-flush register reset 제거(41323 큰 덩어리). en-gating+FILL 정합 보장. **iverilog X-propagation 재검증 필수.**

> **다음 작업자에게**: 190(or 188) impl → WNS≥0 면 HW(N=100→10000, class match 10000/10000 유지 + wall-clock ~0.099s 확인) → **그 다음은 Winograd(§13.5)**. 300 은 §13.2 OTHER 다전선이라 보류(ROI 낮음).

### 13.5 다음 best 레버: Winograd (MHz 졸업 후)
190MHz 로 datapath 클럭은 한계 도달 → 추가 가속은 **알고리즘 복잡도**에서. conv2 가 throughput floor(1799 cyc/img, 3×3 conv 의 9-MAC/output). **Winograd F(2×2, 3×3)** 은 4 output 을 4×4 tile 로 묶어 16 MAC 으로 처리(naive 36 대비 **2.25× 곱셈 감소**) → conv2 cycle/img 대폭 ↓. 참고자료 `docs/pdfs/Winograd`. 적용 시 고려: (a) input/weight transform(상수 행렬, INT8→transform 후 비트폭 증가 주의), (b) DSP packing 재설계(현 SIMD INT8×2 packing 과 호환성), (c) conv1(5×5?)·fc 는 별개. → conv2 우선, 별도 설계문서로.

### 13.6 ★ HW 측정 결과 — 오버클럭은 적용됐으나 latency 불변 (feed-bound 판명, 2026-06-04)
clk_wiz `clk_out3` 가 188 요청 → **200MHz 로 스냅**(`report_clocks`: clk_out3 period 5.000ns, ×2). impl WNS +0.04 로 닫힘, HW **class match 10000/10000** ✅. **그러나 latency = 18,771,076 cyc @100MHz timer = 0.188s = baseline 그대로** (오버클럭 전후 0% 변화).
- **timer 검증**: CSR(`csr_axi_1`)는 `clk_out1`=100MHz 도메인의 wall-clock 카운터(RTL `csr_axi_slave_lite_..._csr.v`: 100MHz 매 cycle +1). `us=cyc/100` 정확. → 측정 신뢰 가능, 오버클럭이 wall-clock 을 안 줄인 게 사실.
- **~~feed-bound 실증(100 vs 200 동일 18.77M)~~ → ★오염 판명, §13.7 로 정정**: 그 200MHz 비교가 **silent timing fail 상태의 broken 빌드**였음(아래 §13.7). 실제로는 100MHz=accel-bound, 150MHz=CDMA-bound 로 클럭이 100→150 에서 도움됨.
- **결론(병목 모델 정정)**: 가속기 100→200MHz(2×)인데 wall-clock 0 변화 = **compute-bound 아님 → PS feed-bound @100MHz**. firmware 루프가 `poll(can_load)+blocking CDMA(196w)+img_ready` 직렬 ≈ **1877 cyc/img @100MHz**. baseline 은 conv2(1799)≈feed(1877) **공동제약**(="가속기-bound" 판정은 아슬한 것)이라, 가속기만 올리니 feed(100MHz)가 floor 로 노출. profile "accel-wait 63%"는 can_load 대기(feed/handshake 페이싱)이지 순수 compute 아님.
- **재우선순위**: **오버클럭·Winograd 는 현재 latency 를 못 줄임**(가속기는 이미 feed 보다 빠름). 다음 레버 = **100MHz 입력 feed 파이프라인**: blocking CDMA 를 앞서 달리게(multi-buffer / SG-queue), 입력 bank >2, can_load 핸드셰이크 round-trip 축소 → 목표 <900 cyc/img @100MHz(200MHz 가속기 매칭). Winograd(conv2 compute↓, §13.5)는 feed 를 먼저 풀어 다시 compute-bound 가 된 뒤에야 효과.
- **확정 실험(선택)**: clk_out3=100 vs 200 에서 profile `t_canload` 비교 — 거의 같으면 feed-bound 확정. (2×→0 만으로도 사실상 결론.)
- firmware(`vitis/main.c`) 주석·출력·bottleneck 메시지를 이 발견에 맞게 정정(clk 200MHz, feed-bound, "다음=feed 파이프라인").

---
*관련: `docs/ip_spec/block_memory_generator.md`(BMG L=2/REGCEB), `docs/conv1_timing.md`, `RTL/conv2/conv2_timing.md`, memory `overclock-300mhz-kickoff`.*
