# Paiement Orange Money : mode d'emploi

Le parent paie les séances confirmées par **Orange Money**. Il est redirigé vers la page sécurisée d'Orange, tape son numéro et son **code secret**, et le paiement est confirmé automatiquement. Personne (ni le parent, ni un admin) ne peut valider un paiement à la main.

Le parent paie **tous les frais de transaction** :

| Ligne | Calcul |
|---|---|
| Séances | somme des séances confirmées |
| Frais Soutra Money (Tutora + → répétiteur) | séances × `so_pct` % + `so_fixe` GNF |
| Frais Orange Money (parent → Tutora +) | calculés pour qu'après la commission Orange, il reste exactement de quoi payer les séances et les frais Soutra |
| **Total** | (séances + frais Soutra) ÷ (1 − `om_pct` %), arrondi au GNF supérieur |

Exemple avec 2 % Orange et 1 % Soutra : 50 000 GNF de séances → 500 GNF de frais Soutra + 1 031 GNF de frais Orange = **51 531 GNF**.

Les taux se règlent dans **Admin → Paramètres**. Remplacez les valeurs par défaut (2 % et 1 %) par les taux exacts donnés par Orange et Soutra. Le montant payé est toujours recalculé par le serveur.

---

## 1. Mettre à jour la base (une seule fois)

Supabase → **SQL Editor** → collez tout le fichier `paiement-orange-money.sql` → **Run**.
On peut le relancer sans risque.

## 2. Déployer les 3 fonctions serveur

| Fonction | Rôle | Vérification JWT |
|---|---|---|
| `om-init` | crée la page de paiement Orange | **activée** |
| `om-check` | vérifie le statut (retour d'Orange, bouton Actualiser) | **activée** |
| `om-notify` | reçoit la confirmation d'Orange | **désactivée** (Orange n'a pas de compte Supabase) |

**Avec le terminal** (le plus simple, `config.toml` règle déjà le JWT) :

```bash
npx supabase login
npx supabase link --project-ref cuoxjhctyegmwakuourm
npx supabase functions deploy om-init
npx supabase functions deploy om-check
npx supabase functions deploy om-notify --no-verify-jwt
```

**Sans terminal** : Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor**. Créez chaque fonction avec son nom, collez le contenu de son `index.ts`, et ajoutez un fichier `_shared/orange.ts` (ou collez son contenu en haut de chaque fonction, à la place de la ligne `import … from "../_shared/orange.ts"`). Pour `om-notify`, désactivez **Enforce JWT verification** dans ses réglages.

## 3. Ajouter les secrets

Supabase → **Edge Functions** → **Secrets** (ou `npx supabase secrets set NOM=valeur`) :

| Secret | Valeur |
|---|---|
| `OM_CLIENT_ID` | donné par Orange (portail développeur) |
| `OM_CLIENT_SECRET` | donné par Orange |
| `OM_MERCHANT_KEY` | clé marchand donnée par Orange |
| `OM_WEBPAY_PATH` | test : `/orange-money-webpay/dev/v1` · production : le chemin Guinée donné par Orange |
| `OM_CURRENCY` | test : `OUV` · production : `GNF` |
| `SITE_URL` | l'adresse de votre site GitHub, ex. `https://lilafna.github.io/Tutora-plus` |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` et `SUPABASE_SERVICE_ROLE_KEY` sont fournis automatiquement par Supabase.
Si Orange vous donne une autre adresse d'API ou de jeton, ajoutez `OM_API_BASE` ou `OM_TOKEN_PATH`.

⚠️ Ne mettez **jamais** ces clés dans `index.html` ni sur GitHub.

## 4. Tester avant d'ouvrir aux parents

1. Avec les accès de **test** (sandbox) d'Orange, faites un paiement depuis un compte parent de test.
2. Vérifiez dans **Admin → Paiements** qu'il passe de « En attente » à « Payé » tout seul.
3. Testez aussi l'annulation sur la page Orange : le paiement doit passer à « Échoué » et le parent doit pouvoir réessayer.
4. En cas de problème : Supabase → **Edge Functions** → la fonction → **Logs**.

Ensuite, remplacez les secrets de test par ceux de **production**.

---

## Comment ça marche (sécurité)

1. Le parent clique sur **Payer**. `om-init` demande à la base de calculer le montant (`start_payment`) : l'appli ne peut pas le modifier.
2. Orange renvoie une page de paiement. Ses jetons sont rangés dans `payment_secrets`, une table que seul le serveur peut lire.
3. Le parent tape son code secret chez Orange.
4. Orange prévient `om-notify`. On ne croit pas le message sur parole : on **redemande le statut à Orange** avant de valider.
5. Si la notification se perd, le retour sur le site et le bouton **Actualiser** (`om-check`) font la même vérification.
6. `confirm_payment` marque les séances payées. Un double message d'Orange ne peut pas valider deux fois.
