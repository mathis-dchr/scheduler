#!/bin/bash
set -e # arrêter le script en cas d'erreur

export DEBIAN_FRONTEND=noninteractive # empêcher les écrans interactifs (ex: choix du clavier ou du fuseau horaire) de bloquer l'installation

echo "=== Installation des dépendances ==="

echo ""
echo "==> Mise à jour des paquets de base..."
sudo apt update

# Installation de Visual Studio Code
echo ""
echo "==> Téléchargement de VS Code..."
wget -qO /tmp/vscode.deb "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64"

echo ""
echo "==> Installation de VS Code..."
sudo DEBIAN_FRONTEND=noninteractive apt install -y /tmp/vscode.deb

# Nettoyage du fichier d'installation
rm /tmp/vscode.deb

# Installation de srsRAN
echo ""
echo "==> Préparation des dépôts logiciels..."
sudo apt install -y software-properties-common # pour s'assurer de sudo add-apt-repository

echo ""
echo "==> Activation du dépôt 'universe' pour les dépendances radio..."
sudo add-apt-repository -y universe

echo ""
echo "==> Ajout du dépôt officiel srsRAN (PPA)..."
sudo add-apt-repository -y ppa:softwareradiosystems/srsran
sudo apt update

# Installation de srsRAN avec apt en version 22.10
#echo ""
#echo "==> Installation de srsRAN..."
#sudo DEBIAN_FRONTEND=noninteractive apt install -y srsran=22.10-0ubuntu1~srsran1~22.04
#sudo apt-mark hold srsran # pour figer la version 22.10

# Compilation de srsRAN (dernière version)
sudo apt install -y cmake build-essential pkg-config libfftw3-dev libmbedtls-dev libboost-all-dev libsctp-dev lksctp-tools libconfig++-dev
mkdir build
cmake -S srsRAN_4G -B build
cmake --build build -j"$(nproc)"

# Installation de srsRAN
cd build
sudo make install
sudo srsran_install_configs.sh user

echo ""
echo "=== Toutes les dépendances ont été installées avec succès ==="

echo ""
echo "==> Ouverture de Visual Studio Code..."
code . & # lancement de VS Code dans le dossier actuel (la racine du dépôt) en arrière-plan
