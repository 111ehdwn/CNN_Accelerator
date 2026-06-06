# Overclock Journey — 100 → 150 → 200 MHz (CNN Accelerator, Arty A7-100T)

> 가속기 datapath 클럭을 100MHz baseline 에서 200MHz 로 끌어올린 전 과정의 **서사적 기록** — 무엇이 병목이었고, 어떤 가설을 세웠다 버렸고, 각 장벽을 어떻게 닫았는지.
> 깊은 스펙/수치는 `docs/overclock_300mhz.md`(기술 레퍼런스), 모듈 타이밍은 `RTL/conv2/conv2_timing.md` 등. 이 문서는 **사고 과정 + 디버깅 로그** 중심.
> 작성: 2026-06-04.

---

## 0. TL;DR — 한눈에 보는 여정

| 구간 | 진짜 병목 | 핵심 레버 | 결과 |
|---|---|---|---|
| **인프라** | (클럭 자체가 없음 — single clock) | dual-clock CDC + BD clk_wiz `clk_out3` + XDC `set_max_delay -datapath_only` | 가속기 datapath 를 PS/AXI(100MHz)와 분리 |
| **100 → 150** | **conv2 broadcast fanout** (192 PE die-spanning, route 지배) | Step1 `max_fanout=32`(state/kw_cnt) + Step1b(weight bc +1reg) + Step2(`PE_BC_DELAY` PE입력 파이프) + weight_loader nested-multiply→accumulator | **150MHz HW 10000/10000 확정** |
| **(우회로)** | — | "feed-bound(클럭 무관)" 가설 → **검증 불가로 폐기** | 200MHz silently fail 했던 빌드가 혼동의 원인 |
| **150 → 200** | **reset fanout** (`rst_sync` 단일 net fo=41323, −1.94, route 85%) | **reset 복제 트리**(`rst_l1`→`rst_leaf` max_fanout) → conv2 **shift_en max_fanout** → **phys_opt AggressiveExplore** | **200MHz 실 HW 10000/10000, 108.9ms** (WNS +0.011, baseline 0.188s 대비 1.72×) |

핵심 교훈 한 줄: **이 칩의 datapath 타이밍 벽은 거의 전부 "die 전역으로 퍼지는 high-fanout 제어/리셋 net 의 route delay"였고, 해법은 로직 재설계가 아니라 `max_fanout` 으로 driver 를 클러스터 근처에 복제하는 것**이었다.

---

## 1. 배경 — 왜 오버클럭인가

파이프라인: `Input BRAM → Conv1 → Conv2 → Maxpool → FC → class`. 각 stage 는 중앙 컨트롤러 없이 자체 FSM + in-flight 핸드셰이크로 분산 제어. PS(MicroBlaze)가 AXI4-Lite CSR 로 start/enable, AXI BRAM/CDMA 로 weight·image 공급.

- **Baseline (committed `4c5dedb`)**: 전부 single 100MHz. PS-side 최적화(can_load-paced inter-image pipelining + AXI CDMA input DMA)로 N=10000 **0.188s, 10000/10000** 까지 옴 (누적 5.8×, [[vitis-mainc-bringup]]).
- 그 다음 레버 후보: **가속기 datapath 클럭 ↑** (conv2 가 throughput floor ~1799 cyc/img). 같은 cycle 거동을 더 빠른 클럭에서 돌리면 wall-clock 단축. **firmware 무변경**(timer 가 세는 100MHz wall-clock cycle 수가 줄어듦).

목표는 처음엔 300MHz(3×)였고, 현실적으로 200MHz 에서 닫혔다. 이 문서는 그 사이의 모든 결정이다.

---

## 2. 인프라 — dual-clock 으로 datapath 만 분리 (선행 작업)

가속기만 빠른 클럭으로 돌리려면 PS/AXI/CSR(100MHz)와 datapath(빠른 클럭) 사이에 **clock domain crossing(CDC)** 이 필요하다.

- **CDC** (`RTL/cnn_accelerator.v` + `RTL/core/cdc_pulse_sync.v`/`cdc_bit_sync.v`):
  - `aclk`(100MHz) 포트 추가. `enable`=level→2-FF sync, `start`/`img_ready`=1-cycle pulse→**toggle 동기화기**(빠른 클럭에서 pulse 가 N cycle 로 보여 "N배 카운트"되는 것 방지).
  - 도메인별 reset: `rst_a`(100), `rst`(datapath, async-assert/sync-deassert).
  - `img_done`/`input_consumed` 는 datapath→100 방향 CDC, `bram_output` clkb→aclk.
  - **CSR/firmware/엔진/BMG 무변경** (common-clock 골격 유지).
- **BD**: clk_wiz 에 `clk_out3`(datapath) 추가, `cnn_accelerator/clk`→clk_out3, `aclk`→clk_out1(100). MIG ref(200)·ui_clk(81.25) 유지.
- **XDC** (`Arty-a7-100-Master_v2.xdc`): write-bus(100→datapath)를 **`set_max_delay -datapath_only 10.0`** 로. (애초엔 multicycle 였으나, 비정수 클럭비(예: 190:100=1.9:1)에선 multicycle 가 부적합 → max_delay 가 비율 무관·idempotent 해서 안전.) datapath→100 은 `set_false_path`.
- **검증**: iverilog 단일클럭 + **듀얼클럭 `tb_system_axi_multi_2clk` 10/10**(3배카운트/펄스손실/데드락 없음). `report_clock_interaction` 으로 제약 작동 확인. → **CDC 무죄 확정** (이후 어떤 타이밍 문제도 CDC 가 원인이 아니었다). committed `f767a5a`.

> **사고 과정**: "오버클럭이 안 돌면 CDC 탓 아닐까?"를 가장 먼저 의심했고, 듀얼클럭 TB + report_clock_interaction 으로 일찌감치 배제했다. 덕분에 이후 디버깅을 datapath 내부(intra-clock)에만 집중할 수 있었다.

---

## 3. MMCM 제약 — "188MHz 는 존재하지 않는다"

clk_wiz(MMCM)는 `clk_out1=100` + `clk_out2=200`(MIG IDELAYCTRL ref)이 **VCO 주파수를 고정**한다. 그러면 `clk_out3` 는 그 VCO 의 **정수 분주**만 가능 → 실제로 낼 수 있는 값은 **{200, 171.4, 166.7, 150, …}** 의 이산 집합.

- **188MHz 를 요청해도 clk_wiz 가 200MHz 로 스냅**한다. (이게 나중에 silent fail 의 결정적 빌미가 됨 — §5.)
- 그래서 "190/188 로 타협"은 실제로는 불가능했고, 닫을 수 있는 후보는 **171.4 / 166.7 / 150 (낮은 쪽)** 또는 **200 (높은 쪽, 닫히면)** 이었다.

> **교훈**: 클럭 목표를 정하기 전에 MMCM 가 그 주파수를 *실제로* 생성할 수 있는지 먼저 확인할 것. report_clocks 의 실제 period 가 요청값과 다르면 스냅된 것.

---

## 4. 100 → 150 MHz — conv2 broadcast fanout 을 닫다

300MHz 1차 합성: **WNS −2.99, Failing 110302/176215, 전부 `clk_out3→clk_out3`**(datapath intra-clock). CDC·제약은 멀쩡(§2). 워스트는 **conv2 broadcast fanout**.

### 4.1 진단 — 로직 깊이가 아니라 route
- 제어/weight broadcast(`state`/`sel`/`pe_en`/`pe_id`/`packed_w`)가 **192 PE 로 fanout**. DSP **226/240=94%** 사용 → PE 가 die 전역 DSP 컬럼에 깔림 → broadcast 가 본질적으로 **die-spanning**.
- 워스트 path 의 **route 86% / logic 14%**. 즉 **로직 깊이 문제가 아니라 배선 거리 문제**. DSP 위치는 고정이라 floorplan 불가 → **파이프라인 + 복제가 유일 레버**.

### 4.2 레버 (누적)
1. **Step 1 — `max_fanout=32`** (conv2_fsm `state`/`kw_cnt`, weight_loader `pe_id`/`slot_id`/`pe_load_en`) + impl `phys_opt -directive AggressiveFanoutOpt`. → WNS −2.99 → **−2.454** (~173MHz). 복제만으론 부족.
2. **Step 1b — weight broadcast +1 register** (`pe_load_en_dec`/`packed_w`/`slot_id` → `_r`, max_fanout). weight-load 는 1회성이라 compute 무영향(cycle-neutral).
3. **Step 2 — `parameter PE_BC_DELAY`** (기본 1): PE 입력단(`sel`/`pe_en`/`pe_x`)에 +N register 복제 → broadcast 가 PE 클러스터 근처 replica 에서 출발. conv2_fsm `DRAIN_LAST=11+N` 로 정합. → **−2.187**.
4. **weight_loader nested-multiply → accumulator** (`weight_loader.v §4.5`): 주소/pe_id 의 `(((oc*8)+ic)*3+kh)*3+kw` 6-level CARRY4 를 `addr_seq`/`pe_id_seq` 단조증가 accumulator 로 대체. 조합깊이 6→1. (이게 Step1b/2 후 새 워스트였음.)

- **검증**: iverilog `tb_cnn_accelerator_multi` **40/40 bit-exact** (PE_BC_DELAY N=0→1798, 1→1799, 2→1800 cyc/img). 5-lens adversarial 감사(retiming/Step1b/DRAIN/missed-consumer) 전부 CORRECT.

### 4.3 결과
300 은 broadcast 를 닫아도 reset/FSM 잔여(−1.7~−1.94)가 die 전역에 남아 비현실적 → **낮은 쪽으로 내려 150MHz 에서 깨끗이 닫음**. **150MHz 합성 빌드 HW class 10000/10000 확정** (clean 빌드).

---

## 5. 우회로 — 버린 가설 하나 (정직한 기록)

150 이후 "오버클럭을 더 해도 latency 가 안 줄어든다 = feed-bound(클럭 무관)"라는 가설을 세웠었다. 근거는 *"가속기 200MHz 인데 wall-clock 이 100MHz 와 동일(18.77M cyc)"* 이라는 측정.

**→ 이 가설은 폐기했다.** 이유:
- 그 "200MHz 빌드"가 사실 **silently fail 한 빌드**였을 가능성이 큼. **188 로 설정 → clk_wiz 가 200 으로 스냅(§3) → 실제로는 200MHz 로 돌면서 reset 경로(−1.94)가 위반 → 핸드셰이크 깨짐 → 중간에 멈춤/오작동.** 분산 FSM + in-flight 카운터 구조라 reset 타이밍이 깨지면 desync 된다.
- 즉 "같은 wall-clock" 비교가 **깨진 빌드끼리의 비교**였을 수 있어 **확정 불가**. 그래서 관련 결론·주석·메모리를 전부 제거하고, **확실한 사실(150MHz 작동)만** 남겼다.

> **교훈 1**: 측정으로 결론을 내리기 전에 **그 빌드가 timing-clean 인지** 먼저 확인하라. positive WNS @ slow corner 가 아니면 그 HW 측정은 신뢰할 수 없다.
> **교훈 2**: 188→200 스냅처럼 **요청 클럭 ≠ 실제 클럭**이면, Vivado 가 (요청 기준으로) 통과시킨 빌드가 실모드(실제 클럭)에선 위반일 수 있다 = **silent fail**. 이게 "오버클럭이 안 돈다"의 진짜 정체였다.

이 깨달음이 150→200 의 방향을 정했다: **"reset 경로(−1.94)부터 닫자."**

---

## 6. 150 → 200 MHz — reset fanout 을 닫다 (이번 세션의 본편)

300MHz 합성에서 conv2 broadcast 를 닫은 뒤 남은 **최대 WNS = reset net**: `rst_sync_reg → BUFG → (fo=41323) → DSP/RSTB·register`, **−1.94, route 85%, 1343 violating endpoints, die 전역**. 단일 reset net 이 datapath 전 register(~41k)로 직접 fanout → BUFG 글로벌 라우팅으로 die 끝의 DSP 까지 가는 데 너무 오래 걸림.

### 6.1 접근 선택 — tie-0 기각, 복제 트리 채택
- **기각한 안: "self-flush datapath register 의 reset 을 1'b0 으로 제거"**. GSR(config 시 0)+FILL/DRAIN 규율에 기대 reset 부하 자체를 없애는 방식. → **기능 거동을 바꾸고(X-leak 검증 부담), 설계가 fragile**. 기각.
- **채택한 안: reset 복제 트리** (사용자 제안). reset 을 *제거*하지 않고 **분배 구조만** 바꾼다 → **기능 완전 불변, X-leak 위험 0**.

```verilog
// RTL/cnn_accelerator.v — async-assert / sync-deassert 유지한 registered 복제 트리
(* max_fanout = 32 *)  reg rst_l1;     // L1: trunk (few copies)
always @(posedge clk or negedge resetn)
    if (!resetn) rst_l1 <= 1'b1;
    else         rst_l1 <= rst_sync;

(* max_fanout = 128 *) reg rst_leaf;   // L2: leaf (heavily replicated → datapath)
always @(posedge clk or negedge resetn)
    if (!resetn) rst_leaf <= 1'b1;
    else         rst_leaf <= rst_l1;

wire rst = rst_leaf;
```
- `max_fanout` 으로 합성이 `rst_sync(1) → rst_l1(~11) → rst_leaf(~323) → datapath(~41k)` 트리를 **자동 생성**하고, 각 leaf 복제본을 **자기 cluster 근처에 배치** → high-fanout net 이 짧은 local net 다수로 쪼개짐 (BUFG 불필요).
- **async-assert(`negedge resetn`)**: 모든 단이 reset 을 즉시(스큐 0) assert, deassert 만 +2 clk 균일 지연(전체 idle-start 라 무해, leaf 끼리 상대 스큐 0).
- 하류 `if(rst)` 는 **전부 그대로** → 모든 register 동일하게 reset.

> **iverilog 가 이번엔 신뢰할 수 있는 이유**: `TB/models/dsp48e1_model.v` 에 `initial` 블록이 없다 → reset 을 건드리면 DSP register 가 X 로 시작하고 iverilog 가 그 X 를 **실제로 전파**한다. (REGCEB abrupt-stop 함정의 *정반대* — 거긴 sim 이 always-follow 라 못 잡았다, [[bmg-l2-regceb-abrupt-stop]].) 즉 bit-exact PASS = X-leak 없음 = HW(GSR=0) 는 더 안전.
- **검증**: `tb_cnn_accelerator_multi` **40/40** + `tb_system_axi_multi` **10/10** bit-exact (1799 cyc/img 동일). 복제 트리는 기능적으로 완전히 투명.

### 6.2 200MHz impl WNS 진행 — −1.94 가 사라지고, 남은 잔불을 끄다

| 단계 | WNS | Failing | 워스트 path | 조치 |
|---|---|---|---|---|
| reset 트리만 (초기 impl) | **−0.154** | 44 | `wl_inst/pe_id_reg[4]` → `pe_load_en_dec_r[12]/R` (route 82%) | (reset −1.94 **완전 소멸 확인**) |
| + phys_opt (default) | **−0.102** | 31 | `conv2/fsm_inst/state` → `lb2_inst/mem_reg[*]/CE` (route 86%) | default phys_opt 가 이 path group 에서 **plateau** ("WNS did not improve") |
| + conv2 **shift_en max_fanout** (re-impl) | **−0.098** | 1 | (lb2 cluster 거의 닫힘, straggler 1) | RTL §6.3 |
| + **phys_opt `-directive AggressiveExplore`** | **+0.011** | **0** | — | **MET** ✅ |

- 진단 도구: `report_timing_summary` (요약·워스트 1), `report_timing -setup -max_paths 44 -file ...` (위반 전체 덤프). ※ 멀티라인 `foreach … get_timing_paths` 는 Vivado TCL 콘솔 붙여넣기에서 깨지기 쉬움 → **`-file` 리포트가 확실**.
- phys_opt 가 첫 워스트(`pe_load_en_dec_r/R`, weight-loader→PE 디코드)를 닫자 **다음 워스트(line buffer CE)가 노출**됐다 — 전형적인 "양파 까기".

### 6.3 새 워스트 = conv2 `shift_en` (line buffer CE)
- 정체: `shift_en` 은 conv2_fsm 에서 **조합 출력**(`state ∈ {PIPELINE_FILL, COMPUTE_ADVANCE, COMPUTE_WRAP}`). 이게 **8 ic 의 line_buffer/window CE-gen 으로 die 전역 broadcast**. `line_buffer.mem` 이 FF 로 합성되어 각 word CE = `shift_en & (ptr==addr)` (그래서 LUT3+LUT6 2단). far-ic(4–7) 로 가는 route 86%.
- `state`·`kw_cnt` 는 이미 `max_fanout=32` 인데 **`shift_en` 만 빠져 있었다.**
- **수정** (`RTL/conv2/conv2_engine.v` line 74, zero-latency·기능 불변):
```verilog
(* max_fanout = 16 *) wire fsm_shift_en;
```
→ shift_en 디코드를 ic 클러스터 근처에 복제. Failing **31 → 1**. iverilog 40/40 유지(attribute-only).

### 6.4 마지막 한 끗 = phys_opt directive
- default `phys_opt_design` 는 −0.154→−0.102 후 **plateau**. 같은 directive 반복은 무의미.
- **`phys_opt_design -directive AggressiveExplore`** 가 −0.098 → **+0.011 (0 failing)** 로 마감. (retiming/aggressive placement 가 마지막 straggler 를 닫음.)
- ⚠️ **interactive phys_opt 라 그 in-memory design 에서 바로 `write_bitstream`** 해야 한다. impl 을 재실행하면 이 결과가 날아감(−0.098 복귀) → **재현하려면 impl strategy 에 AggressiveExplore post-route phys_opt 를 넣을 것.**

### 6.5 결과
**200MHz timing CLOSED — impl MET, WNS +0.011, TNS 0.000, WHS +0.002, THS 0.** 이건 **positive WNS @ slow(signoff) corner** = 정식 충족(§5 의 −1.94 silent fail 과 근본적으로 다름). 복붙 2파일: `RTL/cnn_accelerator.v` + `RTL/conv2/conv2_engine.v`. 마진 더 원하면 `max_fanout 16→8`.

**★ HW 실측 확정 (2026-06-04): class 10000/10000, latency 10,896,290 cyc = 108.9ms @100MHz timer.** baseline(100MHz) 0.188s 대비 **1.72×**. 2×가 아닌 건 profile in-CDMA(blocking) 72%(7.9M cyc, 100MHz feed=클럭무관) 때문 — 가속기 2×는 compute slice 만 압축. 이 clean 빌드 결과가 §5 의 silent-fail(−1.94, 200=0.188s) 을 사후 확증(정상 200 은 baseline 보다 빨라야 하고, 실제로 0.109s < 0.188s).

---

## 7. 반복된 패턴 & 교훈 (재사용 가능한 지식)

1. **이 칩의 datapath 벽 = high-fanout 제어/리셋 net 의 route delay** (로직 깊이 아님). conv2 broadcast, reset, shift_en 전부 같은 병. 워스트 path 의 logic% vs route% 를 먼저 봐라 — route 지배면 **복제 문제**다.
2. **`max_fanout` driver 복제가 만능 레버**였다: state/kw_cnt(Step1), reset 트리(rst_l1/rst_leaf), shift_en — 전부 같은 한 줄짜리 처방. DSP 위치 고정이라 floorplan 불가한 상황에서 placer 가 복제본을 cluster 근처에 깔도록 시키는 게 핵심.
3. **reset 은 제거하지 말고 분배 구조를 바꿔라**: 복제 트리(async-assert/sync-deassert)는 기능 불변이라 tie-0 보다 안전하고 검증이 거의 공짜.
4. **iverilog X-propagation 의 신뢰성은 sim 모델에 달림**: DSP 모델에 `initial` 이 없어 reset 변경의 X 를 실제로 잡았다(이번엔 신뢰 가능). BMG REGCEB 처럼 sim 이 always-follow 하면 못 잡는다 — 모델을 먼저 확인하라.
5. **positive WNS @ slow corner = 진짜 signoff**. 음수인데 통과한 빌드(요청클럭≠실제클럭 스냅)는 실모드에서 silent fail 한다. HW 측정 신뢰성은 timing-clean 이 전제.
6. **양파 까기**: 워스트 하나를 닫으면 다음이 노출된다. phys_opt 로 한 겹, RTL 복제로 또 한 겹, directive 로 마지막 한 겹.
7. **interactive phys_opt 는 재현성 함정**: strategy 에 안 넣으면 impl 재실행 시 사라진다.

---

## 8. 검증 방법 (로컬, Vivado 없이)
모든 RTL 변경은 push 전에 iverilog 로 bit-exact 검증 ([[iverilog-local-sim]]):
- **신뢰 gate (Mac)** = `TB/multi_img/tb_cnn_accelerator_multi.v` (40/40, local `data/` 경로·L=2 정합) + `tb_system_axi_multi.v` (10/10, AXI+CDC reset 경로).
- 명령: `iverilog -g2012 -y RTL/core -y RTL/conv1 -y RTL/conv2 -y RTL/maxpool -y RTL/fc -y RTL/rtl_pingpong RTL/cnn_accelerator.v RTL/conv2/weight_loader.v TB/models/dsp48e1_model.v TB/models/bmg_sim_models.v TB/multi_img/<tb>.v && vvp a.out`
- (`weight_loader.v` 는 파일명≠모듈명이라 `-y` 가 못 찾음 → 명시 필요. AXI gate 는 `-y RTL/control_status_register` 추가.)

---

## 9. 현재 상태 & 다음 레버
- ✅ **150MHz HW 10000/10000 확정** (0.128s).
- ✅ **200MHz 실 HW 작동 확정 (2026-06-04): class 10000/10000, 108.9ms** (10,896,290 cyc @100MHz timer). impl WNS +0.011 (positive@slow corner=정식). baseline(100MHz) 0.188s 대비 **1.72×**, 150MHz 대비 1.17×.
- **왜 2×가 아니라 1.72× 인가**: profile in-CDMA(blocking) **72%**(7.9M cyc) — CDMA 입력 feed 가 100MHz 도메인(가속기 클럭 무관)이라, 가속기 2×는 compute slice 만 압축. **현재 floor = CDMA feed.**
- **다음 레버 (latency)**: ① **CDMA feed overlap** — non-blocking/prefetch CDMA + 입력 bank>2 로 feed 를 compute 와 겹치면 ~0.08s 근처(이론). ② **복소수 Winograd F(4,3)** (conv2 곱셈 144→46, 3.13×) — golden 작성·10000장 bit-exact 완료, RTL 미착수 ([[winograd-f43-golden]]); feed 를 먼저 푼 뒤 compute-bound 가 되면 효과.

*관련 문서: `docs/overclock_300mhz.md`(기술 스펙·결정 기록), `RTL/conv2/conv2_timing.md`, memory `overclock-300mhz-kickoff`.*
