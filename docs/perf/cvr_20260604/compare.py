#!/usr/bin/env python3
# Compare r8169 (C) vs r8125_rust benchmark CSVs. Aggregates repeats by
# median, computes rust-vs-C delta %, flags regressions (>5% worse on
# throughput/PPS, or worse latency tails), prints a summary table.
import csv, sys, os, statistics as st
from collections import defaultdict

RESDIR = sys.argv[1] if len(sys.argv) > 1 else "."
def load(driver, name):
    p = os.path.join(RESDIR, driver, name)
    if not os.path.exists(p): return []
    with open(p) as f: return list(csv.DictReader(f))

def med(xs):
    xs = [float(x) for x in xs if x not in ("", None)]
    return st.median(xs) if xs else float("nan")

def agg_tput(rows):
    g = defaultdict(lambda: defaultdict(list))
    for r in rows:
        k = (r["mtu"], r["proto"], r["dir"], r["offload"], r["load_pct"])
        g[k]["gbps"].append(r["gbps"]); g[k]["retr"].append(r["retr"])
        g[k]["loss"].append(r["loss_pct"]); g[k]["jit"].append(r["jitter_ms"])
        for c in ("cpu_usr","cpu_sys","cpu_soft","cpu_irq"): g[k][c].append(r[c])
    return {k: {m: med(v) for m,v in d.items()} for k,d in g.items()}

def pct(rust, c):
    if c in (0, None) or c != c: return float("nan")
    return 100.0*(rust-c)/c

def main():
    rt, c8 = load("rust","throughput.csv"), load("r8169","throughput.csv")
    A, B = agg_tput(rt), agg_tput(c8)
    print("="*118)
    print("THROUGHPUT / CPU  (Gbps; cpu = busy softirq%; Δ = rust vs r8169, +=rust faster)")
    print("-"*118)
    print(f"{'mtu':>5} {'proto':>5} {'dir':>6} {'offload':>9} {'load':>5} | {'C Gbps':>8} {'Rust Gbps':>9} {'Δ%':>7} | {'C soft%':>7} {'R soft%':>7} {'C irq%':>6} {'R irq%':>6} | flag")
    regress=[]
    for k in sorted(set(A)|set(B)):
        a, b = A.get(k,{}), B.get(k,{})
        cg, rg = b.get("gbps",float('nan')), a.get("gbps",float('nan'))
        d = pct(rg, cg)
        flag=""
        if d==d and d < -5: flag="REGRESSION"; regress.append((k,"tput",d))
        elif d==d and d > 5: flag="rust+"
        mtu,proto,dr,off,loadpct = k
        print(f"{mtu:>5} {proto:>5} {dr:>6} {off:>9} {loadpct:>5} | {cg:>8.3f} {rg:>9.3f} {d:>7.1f} | {b.get('cpu_soft',float('nan')):>7.2f} {a.get('cpu_soft',float('nan')):>7.2f} {b.get('cpu_irq',float('nan')):>6.2f} {a.get('cpu_irq',float('nan')):>6.2f} | {flag}")
    # latency
    print("="*118); print("LATENCY  ICMP-RTT (us; lower=better; Δ = rust vs r8169)")
    print("-"*70)
    def latmap(rows):
        m={}
        for r in rows: m[(r["mtu"],r["test"])]=r
        return m
    LA, LB = latmap(load("rust","latency.csv")), latmap(load("r8169","latency.csv"))
    print(f"{'mtu':>5} {'test':>16} | {'C p50':>7} {'R p50':>7} {'C p99':>7} {'R p99':>7} {'C p99.9':>8} {'R p99.9':>8} {'C max':>7} {'R max':>7}")
    for k in sorted(set(LA)|set(LB)):
        a,b=LA.get(k,{}),LB.get(k,{})
        def gv(d,f):
            try: return float(d.get(f,'nan'))
            except: return float('nan')
        print(f"{k[0]:>5} {k[1]:>16} | {gv(b,'p50_us'):>7.1f} {gv(a,'p50_us'):>7.1f} {gv(b,'p99_us'):>7.1f} {gv(a,'p99_us'):>7.1f} {gv(b,'p999_us'):>8.1f} {gv(a,'p999_us'):>8.1f} {gv(b,'max_us'):>7.1f} {gv(a,'max_us'):>7.1f}")
        rp999=gv(a,'p999_us'); cp999=gv(b,'p999_us')
        if cp999==cp999 and rp999==rp999 and cp999>0 and rp999>1.5*cp999: regress.append((k,"lat-p99.9",pct(rp999,cp999)))
    # PPS
    print("="*118); print("SMALL-FRAME RX PPS  (peer floods UDP -b0 -l<size>; pps received by DUT)")
    print("-"*70)
    def ppsmap(rows): return {r["framesize"]: r for r in rows}
    PA,PB=ppsmap(load("rust","pps.csv")),ppsmap(load("r8169","pps.csv"))
    print(f"{'frame':>6} | {'C pps':>10} {'Rust pps':>10} {'Δ%':>7} | {'C loss%':>8} {'R loss%':>8}")
    for fs in sorted(set(PA)|set(PB), key=lambda x:int(x)):
        a,b=PA.get(fs,{}),PB.get(fs,{})
        cp=float(b.get('rx_pps',0) or 0); rp=float(a.get('rx_pps',0) or 0); d=pct(rp,cp)
        fl="REGRESSION" if (d==d and d<-5) else ""
        if fl: regress.append((fs,"pps",d))
        print(f"{fs:>6} | {cp:>10.0f} {rp:>10.0f} {d:>7.1f} | {float(b.get('loss_pct',0) or 0):>8.2f} {float(a.get('loss_pct',0) or 0):>8.2f}  {fl}")
    print("="*118)
    if regress:
        print(f"REGRESSIONS (rust >5% worse than C): {len(regress)}")
        for k,kind,d in regress: print(f"  {kind}: {k}  Δ={d:.1f}%")
    else:
        print("NO REGRESSIONS >5% — rust within noise/parity of r8169 across all comparable cells.")

main()
