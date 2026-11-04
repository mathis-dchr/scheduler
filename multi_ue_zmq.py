#!/usr/bin/env python3
"""
Broker GNU Radio pour srsRAN 4G avec ZMQ : 1 eNB, N UEs.

  eNB  TX tcp://*:2000  --> copié vers chaque UE (UE1 RX 2100, UE2 RX 2200, ...)
  UEs  TX 2101, 2201... --> additionnés         --> eNB RX 2001

Usage : python3 multi_ue_zmq.py [nombre_d_UE]   (2 par défaut)
Prérequis : sudo apt-get install gnuradio
"""
import sys
from gnuradio import gr, blocks, zeromq

ENB_TX = "tcp://localhost:2000"  # l'eNB bind *:2000 (tx_port)
ENB_RX = "tcp://*:2001"          # l'eNB se connecte à localhost:2001 (rx_port)


class MultiUE(gr.top_block):
    def __init__(self, n_ue=2):
        gr.top_block.__init__(self, "srsRAN 4G multi-UE ZMQ")
        c = gr.sizeof_gr_complex

        enb_dl = zeromq.req_source(c, 1, ENB_TX, 100, False, -1)
        enb_ul = zeromq.rep_sink(c, 1, ENB_RX, 100, False, -1)
        add = blocks.add_vcc(1)

        for i in range(n_ue):
            port = 2100 + 100 * i  # UE1: 2100/2101, UE2: 2200/2201, ...
            ue_dl = zeromq.rep_sink(c, 1, f"tcp://*:{port}", 100, False, -1)
            ue_ul = zeromq.req_source(c, 1, f"tcp://localhost:{port + 1}", 100, False, -1)
            self.connect(enb_dl, ue_dl)       # downlink : eNB -> chaque UE
            self.connect(ue_ul, (add, i))     # uplink : somme des UEs
            print(f"UE{i + 1}: rx_port=tcp://localhost:{port}, tx_port=tcp://*:{port + 1}")

        self.connect(add, enb_ul)


if __name__ == "__main__":
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    tb = MultiUE(n)
    tb.start()
    try:
        input("Broker démarré. Entrée pour arrêter.\n")
    except (EOFError, KeyboardInterrupt):
        pass
    tb.stop()
    tb.wait()
