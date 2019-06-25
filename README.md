# Demandes magasin
## Description
Permet de gérer les demandes de document en magasin.
## Déploiement
Pour déploier le plugin, executez le script `build.sh`
```
user$ bash build.sh
```
Il va générer une archive kpz dans le répertoire kpz. Vous n'avez plus qu'à l'uploader dans la section Plugin de votre instance Koha
## Changement de version
Pour incrémenter le numéro de version du plugin, modifiez la valeur `VERSION` fichier `package.sh` avant de générer le .kpz.
