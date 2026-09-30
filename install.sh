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

echo ""
echo "==> Installation de srsRAN..."
sudo DEBIAN_FRONTEND=noninteractive apt install -y srsran

echo ""
echo "=== Toutes les dépendances ont été installées avec succès ==="

echo ""
echo "==> Ouverture de Visual Studio Code..."
if [ -d "./scheduler" ]; then # vérifie si le dossier existe avant d'y entrer
    cd ./scheduler
    code . & # le '&' à la fin lance l'application en arrière-plan et libère le terminal
else
    echo "-> AVERTISSEMENT : Le dossier ./scheduler est introuvable."
fi
