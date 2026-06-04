# Timing Evidence — Overclock 100→200MHz (단계별 근거)

각 파일은 **"왜 그 부분을 레지스터로 타이밍을 쪼갰는가(register-split)"의 근거**만 남긴 trim 본 (원본 Vivado 5000줄 덤프는 제거, WNS 요약 + 워스트 path 의 Source→Dest + logic/route 비율만 보존). 서사 전체는 `docs/overclock_journey_100_to_200mhz.md`.

파일명 형식: `<stage>_<freq>_<무엇>_<wns>.{txt=리포트발췌, png=Vivado 요약}`

| Stage | WNS | 워스트 path (무엇이 임계였나) | 내린 결정 (register-split / 복제) | 파일 |
|---|---|---|---|---|
| 01 | −8.6 | FC argmax(17입력)·conv1 9입력 가산이 1-cycle 조합 (100MHz 에서도 위반) | argmax → tournament tree 파이프, conv1_adder_tree 1→4-stage | `01_*_wns-8.6.png` |
| 02 | −2.99 | 300MHz: weight/control broadcast 가 192 PE 로 die 전역 fanout (route 지배) | Step1 `max_fanout=32` + Step1b(weight +1reg) + Step2(`PE_BC_DELAY`) | `02_*_wns-2.99.{png,txt}` |
| 03 | −2.454→−2.187 | Step1 복제 후에도 broadcast 잔존 → Step1b/2 적용; weight-load 격리 실험 | Step1b/Step2 + weight_loader nested-multiply→accumulator | `03_*_wns-2.454.png`, `03_*_wns-2.187.png`, `03_*_weightreg-falsepath-isolation.txt` |
| 04 | +0.04 | (참고) 이전 200MHz 빌드 — Vivado MET 로 보였으나 confounded (silent-fail 의심, journey §5) | — | `04_*_silent-fail-suspect.png` |
| 05 | −0.154 | **200MHz**: reset net(−1.94, fo=41323) **사라짐**(복제 트리 성공). 새 워스트 = wl pe_id→pe_load_en_dec (route 82%) | `rst_l1→rst_leaf` 복제 트리 (cnn_accelerator.v); pe_id path 는 phys_opt 가 닫음 | `05_*_wns-0.154.txt` |
| 06 | −0.102 | default phys_opt plateau. 31 failing 전부 conv2 FSM state→shift_en→far-ic lb2 mem CE (route 86%) | `(*max_fanout=16*) wire fsm_shift_en` → 31→1 | `06_*_lb2-CE.txt` |
| 07 | **+0.011** | `phys_opt -directive AggressiveExplore` (default plateau 돌파) → 0 failing, MET | (impl directive) | `07_*_MET_wns+0.011.txt` |
| 08 | — | **실 HW: class 10000/10000, 108.9ms** (baseline 0.188s 대비 1.72×) | — (검증) | `08_*_HW-result_*.txt` |

핵심 패턴: 워스트가 거의 전부 **route 지배(82~86%)** = 로직 깊이가 아니라 die 전역 high-fanout net 의 배선 거리 문제 → 해법은 로직 재설계가 아니라 **`max_fanout` driver 복제(+필요시 register 파이프)로 cluster 근처 배치**. (자세히 journey §7)
