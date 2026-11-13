#!/bin/bash
# =====================================================================
# Montée en charge du scheduler srsRAN 4G avec ZMQ
#   - un test par nombre d'UE de la liste, avec trafic downlink iperf3
#   - s'arrête au premier test qui échoue (limite de la machine)
#   - protection contre le manque de mémoire, avant et pendant chaque test
#
# usage   : sudo ./run_scaling.sh <duree_en_s> <N1> [N2 ...]
# exemple : sudo ./run_scaling.sh 30 1 2 3 4 5 6 7 8
# copie automatique des résultats (clé USB) :
#           sudo COPIE=/media/ubuntu/MA_CLE ./run_scaling.sh 30 1 2 3 4
# bande plus étroite (moins de charge CPU) :
#           sudo NPRB=25 ./run_scaling.sh 30 2 4 6 8 10 12
# =====================================================================
set -u
DUR=${1:-30}
shift
LISTE_N=${*:-1 2 3 4}

NPRB=${NPRB:-50}         # largeur de bande de la cellule, en PRB
case "$NPRB" in          # fréquence d'échantillonnage correspondante, identique pour l'eNB et toutes les UE
  6)   SRATE=1.92e6 ;;
  15)  SRATE=3.84e6 ;;
  25)  SRATE=5.76e6 ;;
  50)  SRATE=11.52e6 ;;
  75)  SRATE=15.36e6 ;;
  100) SRATE=23.04e6 ;;
  *)   echo "NPRB doit valoir 6, 15, 25, 50, 75 ou 100"; exit 1 ;;
esac
MO_PAR_UE=830           # mémoire estimée par UE (Mo), recalculée après chaque test réussi
MARGE_MO=1000            # mémoire toujours gardée libre pour le système (Mo), ne pas descendre en dessous
COPIE=${COPIE:-}         # dossier où copier les résultats après chaque test (optionnel)

U=${SUDO_USER:-$USER}
UHOME=$(getent passwd "$U" | cut -d: -f6)       # le ~ de l'utilisateur, même sous sudo
REPO=$UHOME/scheduler
CFG=$REPO/config
RES=$UHOME/resultats/scaling_$(date +%Y%m%d_%H%M%S)

imsi_of()  { printf "%015d" $((1010123456780 + $1 - 1)); }   # UE1 -> 001010123456780, UE2 -> ...781
dispo_mo() { awk '/MemAvailable/ {print int($2 / 1024)}' /proc/meminfo; }

stop_all() {
  for prog in srsue srsenb srsepc; do
    pkill -INT -x "$prog"
    for t in $(seq 1 15); do
      pgrep -x "$prog" > /dev/null || break
      sleep 1
    done
    pkill -9 -x "$prog" 2>/dev/null
  done
  pkill -f multi_ue_zmq.py; pkill -x iperf3
  sleep 1
}

sauver() {
  chown -R "$U" "$RES"
  if [ -n "$COPIE" ]; then
    mkdir -p "$COPIE/$(basename "$RES")" && cp -r "$1" "$COPIE/$(basename "$RES")/"
  fi
}

mkdir -p "$RES"
echo "Cellule de $NPRB PRB (échantillonnage $SRATE)"
echo "Mémoire disponible au départ : $(dispo_mo) Mo"

for N in $LISTE_N; do
  OUT=$RES/N$N
  mkdir -p "$OUT"
  echo "=== Test avec $N UE ==="
  stop_all
  ECHEC=0

  # --- Garde-fou mémoire avant le test ---
  DISPO=$(dispo_mo)
  BESOIN=$((N * MO_PAR_UE + MARGE_MO))
  if [ "$DISPO" -lt "$BESOIN" ]; then
    echo "  Mémoire insuffisante : $DISPO Mo disponibles, environ $BESOIN Mo nécessaires. Arrêt de la série."
    rmdir "$OUT" 2>/dev/null
    break
  fi

  # --- Base d'abonnés propre à ce test (IP fixes : UE i -> 172.16.0.(i+1)) ---
  : > "$OUT/user_db.csv"
  for i in $(seq 1 "$N"); do
    echo "ue$i,mil,$(imsi_of "$i"),00112233445566778899aabbccddeeff,opc,63bfa50ee6523365ff14c1f45f88737d,9001,000000001234,7,172.16.0.$((i + 1))" >> "$OUT/user_db.csv"
    ip netns add "ue$i" 2>/dev/null
  done

  # --- EPC ---
  srsepc "$CFG/epc.conf" --hss.db_file="$OUT/user_db.csv" --log.filename="$OUT/epc.log" \
    > "$OUT/epc.out" 2>&1 < /dev/null &
  sleep 3

  # --- eNB ---
  srsenb "$CFG/enb.conf" --enb.n_prb="$NPRB" --rf.device_name=zmq \
    --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://localhost:2001,id=enb,base_srate=$SRATE" \
    --log.all_level=warning --log.mac_level=info --log.filename="$OUT/enb.log" \
    --expert.report_json_enable=true --expert.report_json_filename="$OUT/enb_report.json" \
    --expert.metrics_csv_enable=true --expert.metrics_csv_filename="$OUT/enb_metrics.csv" \
    --expert.metrics_period_secs=1 \
    > "$OUT/enb.out" 2>&1 < /dev/null &
  sleep 3

  # --- UE ---
  for i in $(seq 1 "$N"); do
    p=$((2000 + 100 * i))                       # UE1 : écoute 2100, émet 2101 ; UE2 : 2200/2201 ...
    srsue "$CFG/ue.conf" --rf.device_name=zmq \
      --rf.device_args="tx_port=tcp://*:$((p + 1)),rx_port=tcp://localhost:$p,id=ue$i,base_srate=$SRATE" \
      --usim.imsi="$(imsi_of "$i")" --gw.netns="ue$i" --log.filename="$OUT/ue$i.log" \
      --phy.nof_phy_threads=1 \
      > "$OUT/ue$i.out" 2>&1 < /dev/null &
    disown                                      # bash n'affiche plus « Processus arrêté » à l'arrêt
    sleep 1
    if [ "$(dispo_mo)" -lt "$MARGE_MO" ]; then
      echo "  Mémoire presque pleine pendant le lancement de l'UE $i. Arrêt du test."
      ECHEC=1
      break
    fi
  done

  # --- Broker, en dernier (entrée = tube gardé ouvert, pour qu'un input() ne l'arrête pas) ---
  rm -f "$OUT/broker_in"; mkfifo "$OUT/broker_in"
  python3 "$REPO/multi_ue_zmq.py" "$N" < "$OUT/broker_in" > "$OUT/broker.out" 2>&1 &
  exec 3> "$OUT/broker_in"

  # --- Attente de l'attachement de toutes les UE ---
  n_ok=0
  if [ "$ECHEC" -eq 0 ]; then
    ATTENTE=$((60 + 5 * N))
    for t in $(seq 1 "$ATTENTE"); do
      n_ok=0
      for i in $(seq 1 "$N"); do
        ip netns exec "ue$i" ip -4 addr show tun_srsue 2>/dev/null | grep -q inet && n_ok=$((n_ok + 1))
      done
      [ "$n_ok" -eq "$N" ] && break
      sleep 1
    done
    echo "  $n_ok/$N UE attachées"
    [ "$n_ok" -ne "$N" ] && ECHEC=1
  fi

  # --- Trafic downlink vers toutes les UE en même temps ---
  if [ "$ECHEC" -eq 0 ]; then
    for i in $(seq 1 "$N"); do ip netns exec "ue$i" iperf3 -s -D; done
    sleep 1
    pids=()
    for i in $(seq 1 "$N"); do
      # Sans -R : le serveur EPC envoie vers l'UE = downlink
      iperf3 -c "172.16.0.$((i + 1))" -t "$DUR" -J > "$OUT/iperf_ue$i.json" 2>&1 &
      pids+=($!)
    done

    # Surveillance pendant le trafic : mémoire relevée chaque seconde, arrêt d'urgence si besoin
    echo "seconde;dispo_mo;rss_total_srsue_mo" > "$OUT/memoire.csv"
    s=0
    while kill -0 "${pids[@]}" 2>/dev/null; do
      DISPO=$(dispo_mo)
      RSS=$(ps -o rss= -C srsue | awk '{t += $1} END {print int(t / 1024)}')
      echo "$s;$DISPO;$RSS" >> "$OUT/memoire.csv"
      if [ "$DISPO" -lt "$MARGE_MO" ]; then
        echo "  Mémoire presque pleine pendant le trafic ($DISPO Mo). Arrêt d'urgence du test."
        kill "${pids[@]}" 2>/dev/null
        ECHEC=1
        break
      fi
      sleep 1
      s=$((s + 1))
    done
    wait "${pids[@]}" 2>/dev/null

    # Mémoire réelle par UE, pour mieux estimer le test suivant (+20 % de marge)
    if [ "$ECHEC" -eq 0 ]; then
      MAX_RSS=$(awk -F';' 'NR > 1 && $3 > m {m = $3} END {print m + 0}' "$OUT/memoire.csv")
      PAR_UE=$(( (MAX_RSS * 11 / 10) / N + 1 ))
      [ "$PAR_UE" -gt "$MO_PAR_UE" ] && MO_PAR_UE=$PAR_UE
      echo "  Mémoire mesurée : $((MAX_RSS / N)) Mo par UE (estimation retenue : $MO_PAR_UE Mo)"
    fi
  fi

  exec 3>&-
  stop_all

  if [ "$ECHEC" -eq 1 ]; then
    echo "test échoué avec $N UE ($n_ok/$N attachées)" > "$OUT/ECHEC"
    sauver "$OUT"
    echo "Limite atteinte avec $N UE. Arrêt de la série."
    break
  fi
  sauver "$OUT"
done

chown -R "$U" "$RES"
echo "Résultats dans $RES"
[ -n "$COPIE" ] && echo "Copie dans $COPIE/$(basename "$RES")"