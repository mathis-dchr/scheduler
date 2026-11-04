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
