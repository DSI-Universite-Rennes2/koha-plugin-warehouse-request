# Plugin Koha : Warehouse Request / Demande de communication magasin

Ce plugin Koha permet de gérer et suivre les demandes différées de documents localisés en magasin.

## Fonctionnalités

- définir la politique de circulation des exemplaires communicables, selon le site, la localisation, le type de document ou le statut de l'exemplaire ;
- permettre au lecteur de faire sa demande à l'OPAC (connecteur à développer) et de suivre le traitement de cette dernière via des notifications par mail ou directement sur son compte lecteur ;
- permettre au bibliothécaire de faire la demande pour le lecteur depuis l'interface pro, ;
- toujours côté professionnel, offrir un outil de gestion/suivi des "Demandes magasin", intégré au module circulation, qui permet selon un workflow défini de traiter les demandes (en attente, en traitement, mis à disposition, terminée, annulée, archivée) ;
- permettre l'impression de chaque demande sous la forme de ticket au format A6 (slip) et pdf, ticket qui peut ensuite être utilisé comme fantôme en magasin ; 
- semi-automatiser certaines étapes du worklows via l'activation de cronjobs  : (exemple : fixer des créneaux/levées pour passer automatiquement les demandes "en attente" à "en traitement" et ainsi déclencher l'impression des tickets ou encore passer en "terminée" une demande lorsque l'exemplaire demandé a été mis en prêt sur le compte d'un lecteur) ;


### Roadmap

- possibilité de paramétrer quelles sont les catégories de lecteurs qui sont autorisées à faire des demandes magasin ;
- possibilité de définir un quota (journalier et/ou global) de demandes par lecteur/catégorie de lecteur ;
- possibilité de générer une file d'attente pour un exemplaire qui serait demander plusieurs fois de suite ;
- développer les connecteurs côté OPAC pour que l'usager puisse faire sa demande, il existe déjà via l'API REST, des web services qui permettent d'envisager une interconnexion avec une surcouche de recherche ou un outil de decouverte ;
- pour les demandes réalisées sur des notices de périodiques sans exemplaire : pouvoir générer à la volée un exemplaire qui reprend les informations (numéro, volume, année, etc) issues de la demande du lecteur (problématique des périodiques qui ne sont pas systématiquement bulletinés) ;
- pouvoir valider les étapes du workflow directement avec le code-barres des exemplaires et nom le numéro de la demande ;
- pouvoir attribuer un statut "lost" si une demande est annulée car l'exemplaire n'a pas été trouvé ou est manquant ;

## Installation

Le système de plugin de Koha permet d'ajouter des outils et des rapports supplémentaires à Koha qui sont spécifiques à votre bibliothèque. Les plugins sont installés en téléchargeant les paquets KPZ (Koha Plugin Zip). Un fichier KPZ est une simple archive zip contenant les sources nécessaires au fonctionnement du plugin.

Le système de plugin doit être activé par un administrateur système.

Pour mettre en place le système de plugin Koha, vous devez d'abord apporter quelques modifications à votre installation.

Au niveau du fichier koha-conf.xml, il faut modifier la variable <enable_plugins>0<enable_plugins> en <enable_plugins>1</enable_plugins> 
Ensuite, il faut renseigner le chemin de <pluginsdir> qui doit être positionné en écriture sur le serveur.
Redémarrer le serveur web puis dans les préférences système de koha activer UseKohaPlugins
Dans le module Outils de koha, un nouveau menu "Outils de plugin" apparaitra.

### Pré-requis

- Koha 18.11 minimum (jusqu'à la version 1.1), Koha 20.05 pour la branche master
- Modules Perl:
  - Compress::Bzip2
  - HTML::Barcode::Code128
  - PDF::WebKit
  - Net::AMQP::RabbitMQ (optionnel)

### Étapes d'installation

1. Récupération des sources sur github, via clonage du dépôt : 
```
git clone https://github.com/DSI-Universite-Rennes2/koha-plugin-warehouse-request.git
```
2. Dans le répertoire ainsi créé, exécuter le script bash build.sh pour générer le paquet KPZ du plugin :
```
sh ./build.sh
```
3. Installer le plugin via l'interface d'administration de Koha : module administration > gérer les plugins


## Configuration du plugin

Une fois les étapes précédentes réalisées, le plugin est fonctionnel. Pour pouvoir commencer à l'utiliser il convient de configurer le plugin : 

- ```Nombre de jours de conservation``` : le nombre de jours pendant lequel les documents seront mis de côté avant que la demande soit considérée comme périmée ;
- ```Nombre de jours avant archivage``` : le nombre de jours avant archivage des demandes terminées ;
- ```Sites à activer``` : Sites ou bibliothèques pour lesquelles les demandes magasin seront activées ;
- ```Localisations à activer``` : Localisations pour lesquelles les demandes magasin seront activées ;
- ```Types à activer``` : Types de document autorisés à être communiqué depuis les magasins ;
- ```Statuts à activer``` : Statuts d'exemplaire autorisés à être communiqué depuis les magasins ;

- ```Configuration RabbitMQ``` : Optionnel, permet d'utiliser RabbitMQ pour générer des files pour l'impression des tickets vers un serveur d'impression du type Papercut (voir cronjob ```send-slips.pl```);

## Notifications et ticket

Au moment de l'installation, le plugin va créer 5 lettres de notifications (Outils > Notifciations et tickets):

- ```WR_CANCELED``` : Notification envoyé lorsqu'une demande est annulée (possibilité de paramétrer les raisons de l'annulation au niveau de la liste de valeurs autorisées ```WR_REASON```) ;
- ```WR_COMPLETED``` : Notification envoyée lorsque la demande est terminée ;
- ```WR_PENDING``` :  Notification envoyée lorsque la demande est en attente de prise en charge ;
- ```WR_PROCESSING``` :  Notification envoyée lorsque la demande est en cours de traitement ;
- ```WR_WAITING``` : Types de document autorisés à être communiqué depuis les magasins ;

et un ticket prévu pour l'impression : ```WR_SLIP```

## Cronjobs

Tous les cronjobs disponibles sont les suivants :

Exemple:

```
PERL5LIB=/path/to/koha
KOHA_CONF=/path/to/koha-conf.xml
PATH_TO_PLUGIN=/path/to/plugin

59 8-18 * * 1-6 perl $PATH_TO_PLUGIN/Koha/Plugin/Fr/UnivRennes2/WRM/cronjobs/send-slips.pl # Générer et imprimer les tickets pdf - ici à H:59 minutes entre 8h et 18h du lundi au samedi
* * * * * perl $PATH_TO_PLUGIN/Koha/Plugin/Fr/UnivRennes2/WRM/cronjobs/complete-issued.pl # Pour terminer les demandes dont les exemplaires ont été prêtés aux demandeurs
00 2 * * * perl $PATH_TO_PLUGIN/Koha/Plugin/Fr/UnivRennes2/WRM/cronjobs/archive-wr.pl # Pour archiver les demandes termninées
10 2 * * * perl $PATH_TO_PLUGIN/Koha/Plugin/Fr/UnivRennes2/WRM/cronjobs/purge-wr.pl 90 # Pour nettoyer les anciennes demandes

```

## API REST (routes)

Les web services disponibles sont les suivants :

- ```/api/v1/contrib/wrm/update_status``` : mettre à jour le statut d'une demande
- ```/api/v1/contrib/wrm/request``` : effectuer une nouvelle demande
- ```/api/v1/contrib/wrm/list``` : lister les demandes magasin de l'utilisateur courant
- ```/api/v1/contrib/wrm/list/{borrowernumber}``` : lister les demandes magasin de l'utilisateur donné en paramètre
- ```/api/v1/contrib/wrm/biblio/{biblionumber}``` : retourne les exemplaires communiquables pour une notice donnée
- ```/api/v1/contrib/wrm/count``` : affiche le total de demandes en cours sur une notice bibliographique

## Historique

La version initiale du projet a été développée avec comme un hack du module Article Request de Koha puis a été refactorisé dans un plugin koha.

### Signaler une vulnérabilité
Nous prenons la sécurité au sérieux. Si vous découvrez une vulnérabilité, veuillez nous en informer au plus vite !

S'il vous plait **NE PUBLIEZ PAS** un rapport de bug public. A la place, envoyez nous un rapport privé à [foss-security@univ-rennes2.fr](mailto:foss-security@univ-rennes2.fr).

Les rapports de sécurité sont grandement appréciés et nous vous en remercierons publiquement.

