import 'dart:convert';
import 'dart:io';

enum TunnelMode { proxy, vpn, proxyPerApp }

const String _secretKey = "PingTunnelSecretKey2024!";

// Liste de 2048 mots français intégrée dans le code
const List<String> _wordList = [
  "abandon", "abattre", "abri", "absent", "absolu", "absorber", "abuser", "acier",
  "acteur", "adapter", "adresse", "affaire", "affirmer", "afin", "agir", "agiter",
  "aider", "aile", "ailleurs", "aimer", "ainsi", "ajouter", "album", "aller",
  "alors", "amener", "ami", "amour", "amusant", "an", "ancien", "animal",
  "annee", "annonce", "apercevoir", "appeler", "apporter", "apprendre", "arbre", "argent",
  "arme", "arracher", "arriver", "article", "asile", "asseoir", "assister", "assurer",
  "attacher", "atteindre", "attendre", "aucun", "augmenter", "aussi", "auteur", "auto",
  "autre", "avancer", "avant", "avec", "avenir", "avis", "avoir", "avouer",
  "bague", "balai", "balle", "banane", "bande", "banque", "barbe", "bas",
  "bateau", "battre", "beau", "beaucoup", "bebe", "besoin", "bete", "bien",
  "bientot", "billet", "blanc", "bleu", "boire", "bois", "bon", "bonjour",
  "bord", "bouche", "bouger", "bout", "branche", "bras", "brave", "briser",
  "bruit", "bruler", "brun", "buisson", "bureau", "but", "cabane", "cacher",
  "cadeau", "cafe", "cahier", "calculer", "calme", "camarade", "camp", "canard",
  "capable", "car", "carte", "cas", "casser", "cause", "ce", "cela",
  "celui", "cent", "cependant", "certain", "chaine", "chaise", "chambre", "champ",
  "chance", "changer", "chanter", "chaque", "charger", "chasser", "chat", "chaud",
  "chaussure", "chef", "chemin", "chemise", "cher", "chercher", "cheval", "cheveu",
  "chez", "chien", "chiffre", "choisir", "chose", "ciel", "cinema", "ciseau",
  "clair", "classe", "cle", "coeur", "coin", "colere", "colline", "combat",
  "combien", "commander", "comme", "commencer", "comment", "commun", "comprendre", "compter",
  "conduire", "confiance", "connaitre", "conseil", "content", "continuer", "contre", "copain",
  "coq", "corps", "cote", "coton", "coucher", "couleur", "coup", "couper",
  "cour", "courir", "cours", "court", "couteau", "couvrir", "craindre", "crayon",
  "creuser", "crier", "croire", "cru", "cuisine", "cuisiner", "culotte", "curieux",
  "dame", "danger", "dans", "danser", "date", "de", "debut", "decider",
  "decouvrir", "dedans", "dehors", "deja", "delicat", "demain", "demander", "dent",
  "depart", "depenser", "dernier", "derriere", "des", "desert", "desirer", "dessiner",
  "dessous", "dessus", "deux", "devant", "devenir", "devoir", "dieu", "dimanche",
  "diner", "dire", "discours", "disparaitre", "docteur", "doigt", "donc", "donner",
  "dormir", "dos", "douce", "doute", "doux", "douze", "droit", "droite",
  "dur", "eau", "ecole", "ecouter", "ecrire", "effort", "egal", "eglise",
  "electricite", "elephant", "eleve", "elle", "embrasser", "emmener", "employer", "en",
  "encore", "endroit", "enfant", "enfin", "enlever", "ennemi", "ensemble", "ensuite",
  "entendre", "entier", "entre", "entrer", "envie", "environ", "envoyer", "epais",
  "epaule", "epoque", "erreur", "escalier", "espace", "espece", "esperer", "essayer",
  "essence", "est", "et", "etage", "ete", "etendre", "etoile", "etrange",
  "etre", "etudier", "eux", "eveiller", "evenement", "eviter", "exact", "examen",
  "excuser", "exemple", "exister", "experience", "expliquer", "exprimer", "face", "facile",
  "facon", "faible", "faim", "faire", "fait", "falloir", "famille", "fatigue",
  "faute", "femme", "fenetre", "fer", "ferme", "fermer", "fete", "feu",
  "feuille", "fier", "fievre", "figure", "fil", "fille", "film", "fils",
  "fin", "finir", "fleche", "fleur", "flot", "foi", "fois", "fond",
  "football", "force", "foret", "forme", "fort", "fou", "foule", "frais",
  "framboise", "francais", "frapper", "freiner", "frere", "froid", "fromage", "front",
  "fruit", "fuir", "fumer", "fusil", "gagner", "garage", "garcon", "garde",
  "gauche", "geler", "gens", "gentil", "glace", "glisser", "gorge", "gout",
  "goutte", "grand", "grandir", "gras", "gris", "gros", "groupe", "guerre",
  "habiller", "habiter", "habitude", "haut", "herbe", "heure", "heureux", "hier",
  "histoire", "hiver", "homme", "honte", "horloge", "hors", "hotel", "huit",
  "humain", "ici", "idee", "il", "ile", "image", "immense", "important",
  "incroyable", "indiquer", "instant", "interdire", "inviter", "jamais", "jambe", "jardin",
  "jaune", "je", "jeter", "jeu", "jeune", "joie", "joli", "jouer",
  "jour", "journal", "jus", "jusqu", "juste", "la", "labourer", "lac",
  "laid", "laine", "laisser", "lait", "langue", "lapin", "large", "laver",
  "le", "lecture", "leger", "legume", "lent", "lettre", "leur", "lever",
  "liberte", "libre", "lien", "lieu", "ligne", "limite", "lire", "lit",
  "livre", "loin", "long", "longtemps", "lorsque", "louer", "lourd", "lui",
  "lumiere", "lundi", "lune", "lutte", "machine", "madame", "magasin", "main",
  "maintenant", "mais", "maison", "mal", "maladie", "malgre", "maman", "manger",
  "manquer", "manteau", "marcher", "mardi", "mari", "matin", "mauvais", "me",
  "medecin", "meilleur", "meme", "mener", "mensonge", "mer", "merci", "mere",
  "mesure", "mettre", "meuble", "midi", "mieux", "milieu", "mille", "million",
  "mince", "mine", "minuit", "minute", "moi", "moins", "mois", "monde",
  "monsieur", "montagne", "monter", "montre", "morceau", "mot", "moteur", "mou",
  "mourir", "mouton", "moyen", "muet", "mur", "musique", "nager", "naissance",
  "nappe", "nature", "ne", "neige", "nerveux", "neuf", "nez", "ni",
  "nid", "noir", "nom", "nombre", "non", "nord", "note", "notre",
  "nous", "nouveau", "nuage", "nuit", "numero", "objet", "occuper", "oeil",
  "oeuf", "offrir", "oiseau", "oncle", "ont", "onze", "or", "orange",
  "ordre", "oreille", "orner", "os", "ou", "oublier", "ouest", "oui",
  "ouvert", "ouvrir", "pain", "paix", "palais", "panier", "papa", "papier",
  "par", "parapluie", "parc", "parce", "pardon", "parent", "parfois", "parler",
  "parmi", "part", "partir", "parvenir", "pas", "passer", "patron", "paupiere",
  "payer", "pays", "peau", "peche", "peindre", "peine", "peler", "pelle",
  "pendant", "penser", "perdre", "pere", "permettre", "personne", "petit", "peu",
  "peur", "photo", "phrase", "piece", "pied", "pierre", "pigeon", "pile",
  "pinceau", "pipe", "piscine", "place", "plafond", "plage", "plaindre", "plaire",
  "plaisir", "plan", "planche", "plante", "plat", "plein", "pleurer", "pluie",
  "plus", "plusieurs", "poche", "poele", "poeme", "poesie", "poignet", "point",
  "poire", "poisson", "police", "pomme", "pont", "port", "porte", "porter",
  "poser", "possible", "pot", "poule", "pour", "pousser", "poussiere", "pouvoir",
  "precis", "prefere", "premier", "prendre", "pres", "presque", "pret", "preter",
  "prevoir", "prier", "prix", "probleme", "prochain", "produire", "professeur", "profond",
  "promener", "promettre", "propre", "puis", "pull", "quand", "quant", "quarante",
  "quatre", "que", "quel", "quelque", "question", "queue", "qui", "quinze",
  "quitter", "quoi", "race", "raconter", "radio", "raison", "ramasser", "rapide",
  "rappeler", "rare", "raser", "rasoir", "recevoir", "recherche", "recompense", "reconnaitre",
  "reculer", "refuser", "regarder", "regle", "rein", "remarquer", "remplir", "rencontrer",
  "rendre", "rentrer", "repondre", "reposer", "rester", "retard", "retenir", "retour",
  "retrouver", "reunion", "reussir", "reve", "reveiller", "revenir", "rever", "rien",
  "rire", "riviere", "riz", "robe", "roche", "roi", "rose", "roue",
  "rouge", "route", "ruban", "sable", "sac", "sage", "saigner", "sain",
  "saison", "sale", "salle", "salut", "samedi", "sang", "sans", "sante",
  "sauter", "sauver", "savoir", "savon", "scene", "science", "se", "seau",
  "sec", "seche", "secret", "seigneur", "sein", "seize", "sel", "selon",
  "semaine", "sembler", "semer", "sens", "sentence", "sentir", "separer", "sept",
  "serpent", "serrer", "service", "servir", "seul", "seulement", "siecle", "sien",
  "siffler", "signe", "simple", "singe", "sinon", "site", "six", "soeur",
  "soif", "soin", "soir", "soixante", "sol", "soldat", "soleil", "sombre",
  "somme", "sommeil", "son", "songer", "sortir", "sou", "soudain", "souffrir",
  "souhaiter", "soulever", "soulier", "soupe", "sourire", "sous", "souvent", "sport",
  "stylo", "sucre", "sud", "suffire", "suivre", "sujet", "super", "sur",
  "surement", "surface", "surprendre", "surtout", "surveiller", "sympa", "table", "tache",
  "tante", "tapis", "tard", "tas", "tasse", "te", "tel", "telephone",
  "television", "temps", "tendre", "tenir", "tenter", "terminer", "terre", "tete",
  "the", "ticket", "tien", "timbre", "tirer", "tissu", "toi", "toile",
  "toit", "tomate", "tomber", "ton", "tondre", "tortue", "tot", "toucher",
  "toujours", "tour", "tourner", "tous", "tout", "trace", "train", "trait",
  "tranquille", "transformer", "travail", "travailler", "traverser", "trembler", "trente", "tres",
  "treize", "triste", "trop", "trou", "troupeau", "trouver", "tu", "tuer",
  "type", "un", "usine", "utile", "vache", "vague", "vaincre", "vaisselle",
  "valise", "vallee", "valoir", "vanter", "veau", "vedette", "veille", "velo",
  "vendre", "vendredi", "venir", "vent", "ventre", "verifier", "veritable", "verre",
  "vers", "vert", "veste", "vetement", "veuf", "veux", "viande", "victime",
  "victoire", "vide", "vie", "vieux", "vif", "village", "ville", "vin",
  "vingt", "violent", "visage", "vite", "vitesse", "vivre", "voici", "voie",
  "voila", "voir", "voisin", "voiture", "voix", "voler", "volontiers", "vouloir",
  "voyage", "vrai", "vue", "y", "yeux"
];

class TunnelConfig {
  TunnelConfig({
    required this.serverHost,
    this.serverPort,
    required this.localSocksPort,
    this.key,
    this.username,
    this.password,
    this.hwid,
    required this.mode,
    this.encryptMode,
    this.encryptKey,
    this.interfaceName,
    this.tunDevice,
    this.dns,
    this.proxyPerAppPackages = const <String>[],
  });

  final String serverHost;
  final int? serverPort;
  final int localSocksPort;
  final int? key;
  final String? username;
  final String? password;
  final String? hwid;
  final TunnelMode mode;
  final String? encryptMode;
  final String? encryptKey;
  final String? interfaceName;
  final String? tunDevice;
  final String? dns;
  final List<String> proxyPerAppPackages;

  TunnelConfig copyWith({
    String? serverHost,
    int? serverPort,
    int? localSocksPort,
    int? key,
    String? username,
    String? password,
    String? hwid,
    TunnelMode? mode,
    String? encryptMode,
    String? encryptKey,
    String? interfaceName,
    String? tunDevice,
    String? dns,
    List<String>? proxyPerAppPackages,
  }) {
    return TunnelConfig(
      serverHost: serverHost ?? this.serverHost,
      serverPort: serverPort ?? this.serverPort,
      localSocksPort: localSocksPort ?? this.localSocksPort,
      key: key ?? this.key,
      username: username ?? this.username,
      password: password ?? this.password,
      hwid: hwid ?? this.hwid,
      mode: mode ?? this.mode,
      encryptMode: encryptMode ?? this.encryptMode,
      encryptKey: encryptKey ?? this.encryptKey,
      interfaceName: interfaceName ?? this.interfaceName,
      tunDevice: tunDevice ?? this.tunDevice,
      dns: dns ?? this.dns,
      proxyPerAppPackages: proxyPerAppPackages != null
          ? List<String>.from(proxyPerAppPackages)
          : this.proxyPerAppPackages,
    );
  }

  String serverAddress() {
    if (serverPort == null) return serverHost;
    return "$serverHost:$serverPort";
  }

  int localProxyBackendSocksPort() {
    if (localSocksPort < 1 || localSocksPort > 65535) return 1081;
    if (localSocksPort == 65535) return 65534;
    return localSocksPort + 1;
  }

  Map<String, Object?> toMap() {
    return {
      'serverHost': serverHost,
      'serverPort': serverPort,
      'localSocksPort': localSocksPort,
      'key': key,
      'username': username,
      'password': password,
      'hwid': hwid,
      'mode': switch (mode) {
        TunnelMode.proxy => 'proxy',
        TunnelMode.vpn => 'vpn',
        TunnelMode.proxyPerApp => 'proxy_per_app',
      },
      'encryptMode': encryptMode,
      'encryptKey': encryptKey,
      'interfaceName': interfaceName,
      'tunDevice': tunDevice,
      'dns': dns,
      'proxyPerAppPackages': proxyPerAppPackages,
    };
  }

  String encode() {
    final jsonString = jsonEncode(toMap());
    final bytes = utf8.encode(jsonString);
    final encrypted = List<int>.generate(bytes.length, (i) {
      return bytes[i] ^ _secretKey.codeUnitAt(i % _secretKey.length);
    });
    final compressed = gzip.encode(encrypted);
    final bits = <int>[];
    for (final byte in compressed) {
      for (int i = 7; i >= 0; i--) {
        bits.add((byte >> i) & 1);
      }
    }
    while (bits.length % 11 != 0) {
      bits.add(0);
    }
    final words = <String>[];
    for (int i = 0; i < bits.length; i += 11) {
      int index = 0;
      for (int j = 0; j < 11; j++) {
        index = (index << 1) | bits[i + j];
      }
      words.add(_wordList[index]);
    }
    return words.join('-');
  }

  static TunnelConfig decode(String phrase) {
    final words = phrase.split('-');
    final bits = <int>[];
    for (final word in words) {
      final index = _wordList.indexOf(word);
      if (index < 0) throw FormatException('Mot inconnu: $word');
      for (int i = 10; i >= 0; i--) {
        bits.add((index >> i) & 1);
      }
    }
    while (bits.length % 8 != 0) {
      bits.removeLast();
    }
    final compressed = <int>[];
    for (int i = 0; i < bits.length; i += 8) {
      int byte = 0;
      for (int j = 0; j < 8; j++) {
        byte = (byte << 1) | bits[i + j];
      }
      compressed.add(byte);
    }
    final encrypted = gzip.decode(compressed);
    final decrypted = List<int>.generate(encrypted.length, (i) {
      return encrypted[i] ^ _secretKey.codeUnitAt(i % _secretKey.length);
    });
    final jsonString = utf8.decode(decrypted);
    final map = jsonDecode(jsonString) as Map<String, dynamic>;
    return TunnelConfig.fromMap(map);
  }

  static TunnelConfig fromMap(Map<String, dynamic> map) {
    final modeStr = map['mode'] as String? ?? 'proxy';
    final mode = switch (modeStr) {
      'vpn' => TunnelMode.vpn,
      'proxy_per_app' => TunnelMode.proxyPerApp,
      _ => TunnelMode.proxy,
    };
    return TunnelConfig(
      serverHost: map['serverHost'] as String,
      serverPort: map['serverPort'] as int?,
      localSocksPort: map['localSocksPort'] as int? ?? 1080,
      key: map['key'] as int?,
      username: map['username'] as String?,
      password: map['password'] as String?,
      hwid: map['hwid'] as String?,
      mode: mode,
      encryptMode: map['encryptMode'] as String?,
      encryptKey: map['encryptKey'] as String?,
      interfaceName: map['interfaceName'] as String?,
      tunDevice: map['tunDevice'] as String?,
      dns: map['dns'] as String?,
      proxyPerAppPackages: (map['proxyPerAppPackages'] as List?)?.cast<String>() ?? [],
    );
  }

  static TunnelConfig parse(String uriText) {
    final uri = Uri.parse(uriText.trim());
    if (uri.scheme != 'princ') {
      throw const FormatException('URI scheme must be princ://');
    }
    if (uri.host != 'p') {
      throw const FormatException('Only princ://p/... is supported');
    }
    final phrase = uri.path.replaceAll('/', '');
    return decode(phrase);
  }
}
