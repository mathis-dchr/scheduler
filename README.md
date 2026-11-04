# scheduler

## Lancer srsRAN
- `sudo srsepc ~/scheduler/config/epc.conf`
- `sudo srsenb ~/scheduler/config/enb.conf`
- `sudo srsue ~/scheduler/config/ue.conf`

## Tester avec ZMQ

### Configurer le namespace réseau de l'UE
```bash
sudo ip netns add ue1
```

### Lancer l'EPC
```bash
sudo srsepc ~/scheduler/config/epc.conf
```

### Lancer l'ENB
```bash
sudo srsenb ~/scheduler/config/enb.conf \
  --rf.device_name=zmq \
  --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://localhost:2001,id=enb,base_srate=23.04e6"
```

Avec plus du détails :
```bash
sudo srsenb ~/scheduler/config/enb.conf \
  --rf.device_name=zmq \
  --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://localhost:2001,id=enb,base_srate=23.04e6" \
  --log.all_level=warning --log.mac_level=info --log.filename=/tmp/enb.log \
  --pcap.enable=true --pcap.filename=/tmp/enb_mac.pcap \
  --expert.metrics_csv_enable=true --expert.metrics_csv_filename=/tmp/enb_metrics.csv
```

### Lancer l'UE
```bash
sudo sudo srsue ~/scheduler/config/ue.conf \
  --rf.device_name=zmq \
  --rf.device_args="tx_port=tcp://*:2001,rx_port=tcp://localhost:2000,id=ue,base_srate=23.04e6" \
  --gw.netns=ue1
```

### Tester le trafic
Pour l'uplink : UE -> EPC
```bash
sudo ip netns exec ue1 ping 172.16.0.1
```

Pour le downlink : UPC -> UE
```bash
ping 172.16.0.2
```

### Mesurer le débit avec Iperf
Côté l'UE :
```bash
sudo ip netns exec ue1 iperf3 -s
```

Côté l'EPC en uplink :
```bash
iperf3 -c 172.16.0.2 -t 30
```

Côté l'EPC en downlink :
```bash
iperf3 -c 172.16.0.2 -t 30 -R
```

Ajouter UE2 dans `user_db.csv` **avec l'EPC arrêté** (sinon l'EPC écrase le fichier en s'arrêtant) :
```bash
sed -i -e '$a\' ~/scheduler/config/user_db.csv
echo "ue3,mil,001010123456781,00112233445566778899aabbccddeeff,opc,63bfa50ee6523365ff14c1f45f88737d,8000,000000001234,7,dynamic" >> ~/scheduler/config/user_db.csv
```

### Tout arrêter
À faire avant chaque relance, y compris le broker :
```bash
sudo killall srsue srsenb srsepc
pkill -f multi_ue_zmq.py
```

Vérifier qu'aucun port n'est encore occupé (la commande ne doit rien afficher) :
```bash
ss -ltnp | grep -E ':(2000|2001|2100|2101|2200|2201)'
```

### Configurer les namespaces réseau
```bash
sudo ip netns add ue1
sudo ip netns add ue2
```

### Lancer (dans cet ordre, un terminal par commande)
L'EPC :
```bash
sudo srsepc ~/scheduler/config/epc.conf
```

L'eNB :
```bash
sudo srsenb ~/scheduler/config/enb.conf \
  --rf.device_name=zmq \
  --rf.device_args="fail_on_disconnect=true,tx_port=tcp://*:2000,rx_port=tcp://localhost:2001,id=enb,base_srate=23.04e6"
```

UE1 :
```bash
sudo srsue ~/scheduler/config/ue1.conf
```

UE2 :
```bash
sudo srsue ~/scheduler/config/ue2.conf
```

Le broker, **en dernier** :
```bash
python3 ~/scheduler/multi_ue_zmq.py 2
```

Chaque UE doit afficher `Network attach successful` (IP 172.16.0.2 et 172.16.0.3).

> Si on relance l'eNB ou une UE, il faut aussi relancer le broker.

### Tester le trafic
Uplink : UE -> EPC
```bash
sudo ip netns exec ue1 ping 172.16.0.1
sudo ip netns exec ue2 ping 172.16.0.1
```

Downlink : EPC -> UE
```bash
ping 172.16.0.2
ping 172.16.0.3
```

### Mesurer le débit avec Iperf (les deux UEs en même temps)
Côté UEs (un terminal chacun) :
```bash
sudo ip netns exec ue1 iperf3 -s
sudo ip netns exec ue2 iperf3 -s
```

Côté EPC en uplink (lancer les deux en même temps) :
```bash
iperf3 -c 172.16.0.2 -t 30
iperf3 -c 172.16.0.3 -t 30
```

Côté EPC en downlink :
```bash
iperf3 -c 172.16.0.2 -t 30 -R
iperf3 -c 172.16.0.3 -t 30 -R
```

En UDP avec un débit fixe (augmenter `-b` pour saturer la cellule) :
```bash
iperf3 -c 172.16.0.2 -u -b 5M -t 30 -R
iperf3 -c 172.16.0.3 -u -b 5M -t 30 -R
```

Taper `t` + Entrée dans le terminal de l'eNB pour afficher les métriques par UE.