#!/bin/bash

set -e # arrêter le script en cas d'erreur

REPO_URL="git@github.com:mathis-dchr/scheduler.git" # utiliser l'adresse SSH (git@...) et non l'adresse HTTPS
TARGET_DIR="$HOME/scheduler"
BRANCH="main"

echo "=== Initialisation de l'environnement Ubuntu Live ==="

# Identification de l'utilisateur
echo ""
read -p "Veuillez entrer votre pseudo (pour l'historique git) : " USER_NAME

# Applique un nom par défaut si l'utilisateur appuie sur Entrée sans rien écrire
if [ -z "$USER_NAME" ]; then
    USER_NAME="anonym"
fi
echo "-> Identité git enregistrée : $USER_NAME"
echo ""

# Vérification et installation de Git
if ! command -v git &> /dev/null; then
    echo "-> Git n'est pas installé. Installation en cours..."
    sudo apt-get update
    sudo apt-get install -y git
else
    echo "-> Git est déjà installé."
fi

# Configuration de l'identité dans git
git config --global user.name "$USER_NAME"
git config --global user.email "user@projet.local" # l'email est généré automatiquement avec un faux domaine car seul le nom importe ici

# Configuration de la clé SSH de déploiement
echo "-> Configuration de l'accès SSH..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# Pour générer des clés SSH : ssh-keygen -t ed25519 -C "deploy-key" -f ./deploy-key -N "" (-N "" pour ne pas à mettre de mot de passe)
# Importer la clé sur le repo Github dans Deploy Keys et ajoutez le contenu de la clé publique (deploy-key.pub) et cochez impérativement la case "Allow write access"

# Intégration de la clé privée (remplacer le contenu entre les balises EOF)
cat << 'EOF' > "$HOME/.ssh/id_ed25519"
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDv1bpmtMhEsw8oBRzIXdvM1VUcA+PZtvpGoo5sA/Qo/wAAAJAhIqQZISKk
GQAAAAtzc2gtZWQyNTUxOQAAACDv1bpmtMhEsw8oBRzIXdvM1VUcA+PZtvpGoo5sA/Qo/w
AAAEDvNCky0O6/pfA5j9/POkokKKlJVfQvOHsQKMbQV7eqB+/Vuma0yESzDygFHMhd28zV
VRwD49m2+kaijmwD9Cj/AAAACmRlcGxveS1rZXkBAgM=
-----END OPENSSH PRIVATE KEY-----
EOF

chmod 600 "$HOME/.ssh/id_ed25519" # sécurisation obligatoire de la clé, sinon SSH la rejettera

# Ajout des serveurs Git connus pour éviter le prompt de confirmation interactif (yes/no)
ssh-keyscan github.com gitlab.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

# Connexion, clonage ou mise à jour (pull) du dépôt
if [ -d "$TARGET_DIR/.git" ]; then
    echo "-> Le répertoire $TARGET_DIR existe déjà. Mise à jour (pull)..."
    cd "$TARGET_DIR"
    git pull origin "$BRANCH"
else
    echo "-> Clonage du dépôt depuis $REPO_URL..."
    git clone "$REPO_URL" "$TARGET_DIR"
    cd "$TARGET_DIR"
fi

# Exécution du script d'installation des dépendances
if [ -f "install.sh" ]; then
    echo "-> Fichier install.sh détecté. Installation..."
    chmod +x install.sh
    ./install.sh # exécution du script (le sudo dans install.sh s'appliquera si nécessaire)
else
    echo "-> AVERTISSEMENT : Aucun fichier install.sh trouvé à la racine du dépôt."
fi

echo "=== Environnement prêt ==="

# Pour installer l'environnement :
    # sudo apt update && sudo apt install curl
    # curl -sL https://raw.githubusercontent.com/mathis-dchr/scheduler/refs/heads/main/bootstrap.sh | bash
    # ou alors : curl -sL https://tinyurl.com/mr3hm539 | bash
