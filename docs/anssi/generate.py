#!/usr/bin/env python3
"""Génère les quatre PDF de la déclaration ANSSI (voir docs/anssi/README.md).

    build/venv-docs/bin/python docs/anssi/generate.py

Toutes les informations de l’éditeur sont renseignées en tête de fichier.
"""
import os
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.platypus import ListFlowable, ListItem, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

OUT = os.path.dirname(os.path.abspath(__file__))
AUTHOR = "Stephane Jupille"
APP = "NanoKVM"
VERSION = "Version 1.1"
CONTACT = f"{AUTHOR}, 73 route de Lyon, 69390 Vernaison, France, sjupille@gmail.com"

ss = getSampleStyleSheet()
H1 = ParagraphStyle("H1", parent=ss["Title"], fontSize=22, leading=26, textColor=colors.HexColor("#0b4f9c"), spaceAfter=6)
SUB = ParagraphStyle("Sub", parent=ss["Normal"], fontSize=12, leading=15, textColor=colors.HexColor("#444444"), spaceAfter=14, alignment=1)
H2 = ParagraphStyle("H2", parent=ss["Heading2"], fontSize=14, leading=17, textColor=colors.HexColor("#0b4f9c"), spaceBefore=14, spaceAfter=6)
BODY = ParagraphStyle("Body", parent=ss["Normal"], fontSize=10.5, leading=14.5, spaceAfter=6)
SMALL = ParagraphStyle("Small", parent=BODY, fontSize=8.5, leading=11, textColor=colors.HexColor("#555555"))
CELL = ParagraphStyle("Cell", parent=BODY, fontSize=9.5, leading=12.5, spaceAfter=0)


def p(text, style=BODY):
    return Paragraph(text, style)


def bullets(items):
    return ListFlowable([ListItem(p(i), leftIndent=12) for i in items], bulletType="bullet", start="•", leftIndent=14)


def table(rows, widths, header=True):
    data = [[p(str(c), CELL) for c in r] for r in rows]
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0)
    style = [
        ("GRID", (0, 0), (-1, -1), 0.4, colors.HexColor("#b8c4d6")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ]
    if header:
        style.append(("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#e3ecf8")))
    t.setStyle(TableStyle(style))
    return t


def build(name, title, subtitle, story):
    def footer(canvas, doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 8)
        canvas.setFillColor(colors.HexColor("#777777"))
        canvas.drawString(2 * cm, 1.2 * cm, f"{APP} – {title} – {AUTHOR}")
        canvas.drawRightString(A4[0] - 2 * cm, 1.2 * cm, f"Page {doc.page}")
        canvas.restoreState()

    doc = SimpleDocTemplate(os.path.join(OUT, name), pagesize=A4, leftMargin=2 * cm, rightMargin=2 * cm,
                            topMargin=2 * cm, bottomMargin=2 * cm, title=f"{APP} – {title}", author=AUTHOR,
                            lang="fr-FR")
    head = [p(f"{APP}", H1), p(f"{title}", ParagraphStyle("T", parent=H1, fontSize=15, leading=18, textColor=colors.black)),
            p(subtitle, SUB)]
    doc.build(head + story, onFirstPage=footer, onLaterPages=footer)
    print("écrit", name)


# ---------------------------------------------------------------------------
# Contenu partagé : description factuelle de la cryptologie
# ---------------------------------------------------------------------------
CRYPTO_ROWS = [
    ["Fonction", "Algorithmes et protocoles", "Mise en œuvre"],
    ["Liaison HTTPS / WebSocket sécurisée (WSS) vers le KVM : vidéo, commandes, configuration",
     "TLS (versions et suites négociées par le système d’exploitation)",
     "Bibliothèques du système Apple (URLSession). Aucun code de cryptologie propre à l’application. Le certificat du KVM est auto-signé : l’application l’accepte uniquement pour l’adresse du KVM configuré par l’utilisateur."],
    ["Liaison SSH vers le KVM : changement du mot de passe root, terminal distant",
     "Protocole SSH 2.0. Échange de clés : curve25519-sha256, ecdh-sha2-nistp256/384/521, diffie-hellman-group14-sha1/sha256 (hérité). "
     "Chiffrement : aes128-gcm@openssh.com, aes256-gcm@openssh.com, aes128-ctr, aes256-ctr. "
     "Intégrité : hmac-sha2-256, hmac-sha2-512, hmac-sha1 (hérité). "
     "Clés d’hôte : ssh-ed25519, ecdsa-sha2-nistp256/384/521, ssh-rsa.",
     "Bibliothèque libre Citadel (SSH client), qui s’appuie sur une dérivée de swift-nio-ssh, swift-crypto (CryptoKit d’Apple sur les plateformes Apple, BoringSSL pour RSA) et BigInt. Authentification par mot de passe ; empreinte de la clé d’hôte mémorisée à la première connexion."],
    ["Stockage des identifiants de l’utilisateur",
     "Trousseau Apple (Keychain), éventuellement synchronisé via le trousseau iCloud",
     "Services du système Apple. L’application ne chiffre pas elle-même ces données."],
]
CRYPTO_NOTE = ("Les algorithmes sont ceux des normes publiques (IETF : RFC 4251 à 4254 pour SSH, RFC 5656 pour ECDSA/ECDH, "
               "RFC 8032 pour Ed25519, RFC 8731 pour curve25519 en SSH ; TLS : RFC 8446). "
               "Aucun algorithme propriétaire ou non publié n’est utilisé. La liste exacte négociée lors d’une connexion dépend "
               "du serveur SSH du KVM.")
W3 = [4.2 * cm, 6.8 * cm, 6 * cm]


# ---------------------------------------------------------------------------
# 1. Brochure commerciale
# ---------------------------------------------------------------------------
def commercial():
    s = [
        p("Pilotez votre NanoKVM depuis votre Mac, iPhone et iPad", H2),
        p(f"<b>{APP}</b> est une application native pour macOS, iOS et iPadOS qui remplace l’interface web du boîtier "
          "<b>Sipeed NanoKVM</b> (un KVM sur IP : clavier, vidéo et souris à distance) par une interface Apple fluide, "
          "optimisée pour le tactile et le trackpad."),
        p("Fonctions principales", H2),
        bullets([
            "<b>Écran à distance</b> faible latence (H.264 / H.265), clavier, souris absolue ou relative, collage de texte, "
            "plein écran sur Mac, zoom et défilement tactiles.",
            "<b>Image nette</b> : génération et envoi à la volée d’un EDID adapté à l’écran de votre Mac ou iPad, pour une correspondance 1:1 des pixels.",
            "<b>Médias</b> : liste, envoi, montage et suppression d’images ISO/IMG.",
            "<b>Réveil à distance</b> (Wake-on-LAN) de vos machines.",
            "<b>Réseau</b> : Wi-Fi, Tailscale, nom d’hôte, mDNS.",
            "<b>Réglages avancés</b> du KVM : identité USB, périphériques virtuels, IP fixe, mises à jour, etc.",
            "<b>Mode trackpad (iOS)</b> : gestes réglables pour piloter un curseur à distance.",
            "<b>Terminal SSH intégré</b> et changement du mot de passe root du KVM, pour sécuriser l’accès au boîtier.",
        ]),
        p("Sécurité", H2),
        bullets([
            "Communications avec le KVM chiffrées (HTTPS/WSS) ; accès SSH chiffré.",
            "Identifiants conservés dans le trousseau Apple, jamais en clair dans l’application.",
            "Fonctionne sur votre réseau local ; aucun serveur intermédiaire, aucun compte, aucune collecte de données.",
        ]),
        p("À qui s’adresse l’application ?", H2),
        p("Aux particuliers, passionnés d’informatique, administrateurs de laboratoires ou de serveurs personnels qui possèdent "
          "un NanoKVM et veulent le piloter confortablement depuis un appareil Apple. C’est un logiciel grand public, diffusé "
          "via l’App Store, qui n’est pas conçu pour la cryptologie : le chiffrement n’y sert qu’à protéger la liaison avec le boîtier de l’utilisateur."),
        p("Informations", H2),
        table([
            ["Éditeur", AUTHOR],
            ["Plateformes", "macOS 15 et ultérieur, iOS / iPadOS 17 et ultérieur"],
            ["Distribution", "App Store (Apple)"],
            ["Prix", "Gratuit"],
            ["Contact", CONTACT],
        ], [4 * cm, 13 * cm], header=False),
        Spacer(1, 6),
        p("Sipeed et NanoKVM sont des marques de leurs propriétaires respectifs. Cette application est un logiciel indépendant.", SMALL),
    ]
    build("1-brochure-commerciale.pdf", "Brochure commerciale", f"{VERSION} – {AUTHOR}", s)


# ---------------------------------------------------------------------------
# 2. Brochure technique (datasheet)
# ---------------------------------------------------------------------------
def datasheet():
    s = [
        p("1. Identification", H2),
        table([
            ["Produit", f"{APP} (bundle ID : org.jupille.NanoKVM)"],
            ["Type", "Application logicielle (client) pour macOS, iOS et iPadOS"],
            ["Éditeur", CONTACT],
            ["Version", "1.1"],
            ["Langage / framework", "Swift, SwiftUI"],
            ["Distribution", "App Store uniquement"],
        ], [4.5 * cm, 12.5 * cm], header=False),
        p("2. Fonction générale", H2),
        p("Client d’administration à distance pour un KVM sur IP Sipeed NanoKVM. L’application affiche le flux vidéo "
          "du KVM, envoie les frappes clavier et mouvements de souris (HID), et pilote la configuration du boîtier via son API HTTPS. "
          "Elle n’offre ni service de messagerie, ni VPN, ni coffre-fort, ni stockage chiffré, ni antivirus."),
        p("3. Cryptologie : fonctions et algorithmes", H2),
        p("La cryptologie n’est pas la fonction principale du produit : elle protège uniquement la liaison entre l’appareil de l’utilisateur "
          "et le KVM qu’il possède, ainsi que l’accès SSH à ce boîtier."),
        table(CRYPTO_ROWS, W3),
        Spacer(1, 6),
        p(CRYPTO_NOTE),
        p("4. Ce que la cryptologie ne fait pas", H2),
        bullets([
            "Aucune fonction n’est mise à la disposition de l’utilisateur pour chiffrer, déchiffrer, signer ou hacher ses propres données.",
            "Aucune interface de programmation de cryptologie n’est exposée à d’autres applications.",
            "L’utilisateur ne peut ni choisir, ni modifier, ni ajouter d’algorithmes, ni gérer des clés cryptographiques (hors mot de passe SSH).",
            "L’application n’implémente aucun algorithme propriétaire et n’inclut aucun mécanisme de séquestre ou de contournement.",
            "Aucune donnée n’est envoyée à l’éditeur ni à un tiers : les communications se font entre l’appareil de l’utilisateur et son KVM.",
        ]),
        p("5. Gestion des clés et des secrets", H2),
        bullets([
            "Mots de passe de connexion au KVM (web et SSH) : saisis par l’utilisateur, stockés dans le trousseau Apple.",
            "Clés d’hôte SSH : l’empreinte de la clé publique du KVM est mémorisée à la première connexion (trust on first use) et comparée aux suivantes.",
            "Clés de session TLS et SSH : générées à la connexion par le système ou la bibliothèque, non conservées.",
        ]),
        p("6. Composants tiers", H2),
        table([
            ["Composant", "Rôle", "Licence"],
            ["Citadel (orlandos-nl)", "Client SSH", "MIT"],
            ["swift-nio-ssh (dérivée)", "Protocole SSH 2.0", "Apache 2.0"],
            ["swift-crypto (Apple)", "Primitives (CryptoKit sur plateformes Apple ; BoringSSL pour RSA)", "Apache 2.0"],
            ["BigInt", "Arithmétique grands entiers (RSA)", "MIT"],
            ["SwiftTerm", "Émulation de terminal (affichage, sans cryptologie)", "MIT"],
        ], [5 * cm, 8 * cm, 4 * cm]),
        Spacer(1, 6),
        p(f"Les versions exactes des composants et la liste négociée en pratique seront fournies sur demande. Référence : état du code au 16/11/2026.", SMALL),
    ]
    build("2-brochure-technique.pdf", "Brochure technique (datasheet)", f"{VERSION} – {AUTHOR}", s)


# ---------------------------------------------------------------------------
# 3. Manuel utilisateur
# ---------------------------------------------------------------------------
def manual():
    s = [
        p("1. Prérequis", H2),
        bullets([
            "Un boîtier <b>Sipeed NanoKVM</b> branché sur votre réseau et relié à l’ordinateur à piloter.",
            "Un Mac (macOS 15 ou ultérieur), un iPhone ou un iPad (iOS / iPadOS 17 ou ultérieur) sur le même réseau.",
            "L’adresse du KVM (ou sa découverte automatique) et son identifiant web.",
        ]),
        p("2. Première connexion", H2),
        bullets([
            "Ouvrez l’application. Les KVM du réseau local sont détectés automatiquement (Bonjour) ; sinon, ajoutez-en un avec son adresse.",
            "Saisissez l’identifiant et le mot de passe web du KVM. Ils sont enregistrés dans le trousseau Apple.",
            "La liaison est chiffrée (HTTPS). Le KVM utilise un certificat auto-signé, accepté uniquement pour l’adresse que vous avez configurée.",
        ]),
        p("3. Utiliser l’écran", H2),
        bullets([
            "<b>Écran</b> : affiche l’ordinateur distant. Souris et clavier sont transmis. Sur iPhone/iPad, le bouton « Clavier » ouvre le clavier.",
            "<b>Réglages</b> : qualité vidéo, codec, images par seconde, EDID (adapter la résolution du KVM à votre écran), mode du pointeur.",
            "<b>Réglage des gestes</b> (iOS) : ajustez les délais et sensibilités des gestes (toucher, double toucher, défilement…).",
            "<b>Médias</b>, <b>Réveil</b>, <b>Réseau</b>, <b>Services</b>, <b>Appareil</b>, <b>Avancé</b> : voir la barre latérale.",
        ]),
        p("4. Accès SSH et mot de passe root", H2),
        p("Dans <b>Avancé › Accès root</b> :"),
        bullets([
            "Le mot de passe root du KVM est par défaut « sipeed » ; l’application vous avertit tant qu’il est probablement inchangé. <b>Changez-le.</b>",
            "Saisissez un nouveau mot de passe (différent du mot de passe par défaut) et confirmez-le : il est appliqué sur le KVM via une connexion SSH chiffrée.",
            "Le bouton « Terminal » ouvre une fenêtre de terminal SSH. Au premier accès, l’empreinte de la clé du KVM est mémorisée ; si elle change plus tard, la connexion est refusée (protection contre l’usurpation).",
            "« Oublier la clé SSH » réinitialise cette mémorisation (à utiliser après une réinstallation légitime du KVM).",
            "Le service SSH du KVM doit être activé (Réseau › SSH).",
        ]),
        p("5. Sécurité et confidentialité", H2),
        bullets([
            "L’application ne collecte aucune donnée et n’utilise aucun serveur de l’éditeur.",
            "Les mots de passe sont stockés dans le trousseau Apple, éventuellement synchronisé par iCloud selon vos réglages.",
            "Ne partagez pas vos identifiants ; changez les mots de passe par défaut du KVM.",
        ]),
        p("6. Aide", H2),
        p(f"Contact : {CONTACT}."),
    ]
    build("3-manuel-utilisateur.pdf", "Manuel utilisateur", f"{VERSION} – {AUTHOR}", s)


# ---------------------------------------------------------------------------
# 4. Guide administrateur
# ---------------------------------------------------------------------------
def admin():
    s = [
        p("1. Objet", H2),
        p("Ce guide s’adresse à la personne qui installe, configure et sécurise l’application et le KVM. "
          "L’application est un client : elle ne comprend aucun serveur, aucune console d’administration, aucun compte centralisé."),
        p("2. Installation", H2),
        bullets([
            "Téléchargement depuis l’App Store. Aucune installation ni configuration supplémentaire n’est requise.",
            "L’application n’a pas besoin de privilèges particuliers. Elle demande l’accès au réseau local (pour joindre le KVM).",
        ]),
        p("3. Configuration de la cryptologie", H2),
        p("Les paramètres de cryptologie ne sont pas modifiables par l’administrateur ni par l’utilisateur :"),
        bullets([
            "<b>TLS</b> : négocié par le système d’exploitation ; il se met à jour avec les mises à jour d’iOS, iPadOS et macOS.",
            "<b>SSH</b> : les algorithmes sont ceux de la bibliothèque embarquée (voir la brochure technique) ; la liste négociée dépend du serveur SSH du KVM.",
            "Aucune clé n’est à générer ni à distribuer. L’authentification SSH se fait par mot de passe.",
        ]),
        p("4. Recommandations de sécurisation du KVM", H2),
        bullets([
            "Changer le mot de passe web par défaut et le mot de passe root (« sipeed ») dès la première utilisation.",
            "Activer l’authentification à deux facteurs sur le KVM si le micrologiciel le permet.",
            "N’exposer le KVM que sur un réseau de confiance ou derrière un VPN ; ne pas le publier sur Internet.",
            "Désactiver le service SSH du KVM lorsqu’il n’est pas utilisé.",
            "Maintenir le micrologiciel du KVM à jour (Appareil › Mises à jour).",
        ]),
        p("5. Gestion des secrets", H2),
        bullets([
            "Les mots de passe sont stockés dans le trousseau Apple de l’utilisateur ; supprimer l’appareil de l’application supprime les mots de passe associés.",
            "L’empreinte de clé d’hôte SSH est mémorisée dans les préférences de l’application ; « Oublier la clé SSH » la supprime.",
            "Le changement du mot de passe root s’effectue par une commande exécutée sur le KVM via SSH ; le mot de passe n’est pas journalisé par l’application.",
        ]),
        p("6. Journalisation et données", H2),
        p("L’application ne transmet aucune donnée à l’éditeur et ne tient pas de journal d’audit. Les seules données conservées localement "
          "sont la liste des KVM (nom, adresse), les préférences et les mots de passe dans le trousseau."),
        p("7. Dépannage", H2),
        bullets([
            "« Connexion refusée » : vérifier l’adresse du KVM, que le service SSH est activé, et que le mot de passe est correct.",
            "« Clé d’hôte modifiée » : le KVM a peut-être été réinstallé ; si c’est le cas, utiliser « Oublier la clé SSH » puis se reconnecter. Sinon, considérer qu’il y a un risque d’usurpation.",
        ]),
        p("8. Contact", H2),
        p(CONTACT),
    ]
    build("4-guide-administrateur.pdf", "Guide administrateur", f"{VERSION} – {AUTHOR}", s)

# ---------------------------------------------------------------------------
# 5. Attestation (texte officiel ANSSI, champs remplis)
# ---------------------------------------------------------------------------
def attestation():
    legal = ("représentant le déclarant et/ou le demandeur, certifie que les renseignements figurant dans le formulaire "
             "auquel cette attestation est jointe, ainsi que l’ensemble de ses pièces, sont exacts et ont été établis de bonne foi "
             "et que le déclarant et/ou le demandeur s’engage à porter à la connaissance de l’Agence nationale de la sécurité des "
             "systèmes d’information sans délai tout élément nouveau de fait ou de droit de nature à modifier cette déclaration "
             "et/ou cette demande d’autorisation ou les éléments joints, toute omission ou toute fausse déclaration exposant le "
             "déclarant et/ou le demandeur aux sanctions prévues aux articles 34 et 35 de la loi n° 2004-575 du 21 juin 2004 modifiée.")
    s = [
        p("Je soussigné :", H2),
        table([
            ["Civilité :", "Monsieur"],
            ["Nom :", "Jupille"],
            ["Prénoms :", "Stephane"],
            ["agissant en la qualité de :", "Éditeur (personne physique)"],
            ["pour le compte de :", "lui-même (Stephane Jupille), 73 route de Lyon, 69390 Vernaison"],
        ], [6 * cm, 11 * cm], header=False),
        Spacer(1, 10),
        p(legal),
        Spacer(1, 16),
        p("Date : 16/11/2026"),
        Spacer(1, 6),
        p("Signature :"),
        Spacer(1, 70),
    ]
    build("5-attestation.pdf", "Attestation relative aux informations fournies dans le formulaire de déclaration", "", s)


if __name__ == "__main__":
    commercial()
    datasheet()
    manual()
    admin()
    attestation()
