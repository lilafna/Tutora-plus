-- =====================================================================
-- Tutora + : passage du paiement parent à ORANGE MONEY (automatique)
-- À exécuter UNE FOIS dans Supabase > SQL Editor (on peut le relancer sans risque).
-- Le parent paie : séances + frais Orange Money (parent -> Tutora +)
--                 + frais Soutra Money (Tutora + -> répétiteur).
-- =====================================================================

-- 1. Détail du montant dans chaque paiement
alter table payments add column if not exists base int;
alter table payments add column if not exists frais_om int not null default 0;
alter table payments add column if not exists frais_soutra int not null default 0;
alter table payments alter column provider set default 'orange';

-- 2. Jetons Orange Money : table secrète, lisible UNIQUEMENT par le serveur (service_role).
--    Pas de règle d'accès = personne d'autre (ni parent, ni admin) ne peut la lire ou l'écrire.
create table if not exists payment_secrets(
  pay uuid primary key references payments on delete cascade,
  order_id text unique not null,
  pay_token text,
  notif_token text unique,
  created_at timestamptz default now());
alter table payment_secrets enable row level security;
revoke all on payment_secrets from public, anon, authenticated;
grant all on payment_secrets to service_role;

-- 3. Taux de frais (modifiables par l'admin dans Paramètres, en %)
--    om_pct  : frais Orange Money sur l'encaissement (parent -> Tutora +)
--    so_pct  : frais Soutra Money sur le virement au répétiteur (en %)
--    so_fixe : frais fixe Soutra Money par virement (en GNF)
create or replace function cfg_num(key text, def numeric) returns numeric language sql stable security definer set search_path=public as $$
  select coalesce((select nullif(v->>key,'')::numeric from settings where k='cfg'), def) $$;

-- 4. Calcul des frais. Même formule que dans l'appli (affichage).
--    Le total est calculé pour qu'après les frais Orange, il reste de quoi payer
--    le répétiteur ET les frais Soutra : total x (1 - om%) >= séances + frais Soutra.
create or replace function pay_fees(b int) returns json language plpgsql stable security definer set search_path=public as $$
declare om int; so int; sf int; fs int; tot int;
begin
  om := greatest(0, least(round(cfg_num('om_pct', 2)   * 100), 2000))::int;  -- en points de base (2 % = 200), max 20 %
  so := greatest(0, least(round(cfg_num('so_pct', 1)   * 100), 2000))::int;
  sf := greatest(0, round(cfg_num('so_fixe', 0)))::int;
  if coalesce(b,0) <= 0 then return json_build_object('base',0,'frais_om',0,'frais_soutra',0,'total',0); end if;
  fs  := ceil((b::numeric * so) / 10000)::int + sf;
  tot := ceil(((b + fs)::numeric * 10000) / (10000 - om))::int;
  return json_build_object('base', b, 'frais_om', tot - b - fs, 'frais_soutra', fs, 'total', tot);
end $$;

-- 5. Devis affiché au parent (ce qu'il va payer maintenant)
create or replace function payment_quote() returns json language plpgsql stable security definer set search_path=public as $$
declare b int;
begin
  select coalesce(sum(prix),0) into b from notes where pid=auth.uid() and conf and not paid and payment_id is null and prix>0;
  return pay_fees(b);
end $$;

-- 6. Le parent lance un paiement : montant + frais calculés ICI (impossible à trafiquer)
create or replace function start_payment(phone text) returns json language plpgsql security definer set search_path=public as $$
declare b int; f json; pay uuid;
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='parent') then raise exception 'Réservé aux parents'; end if;
  -- libère les séances d'une ancienne tentative restée sans réponse
  update payments set st='Expiré' where pid=auth.uid() and st='En attente' and created_at < now() - interval '30 minutes';
  update notes set payment_id=null where pid=auth.uid() and not paid and payment_id in (select id from payments where st in('Expiré','Échoué','Annulé'));
  if exists(select 1 from payments where pid=auth.uid() and st='En attente') then raise exception 'Un paiement est déjà en cours. Terminez-le sur la page Orange Money ou réessayez dans 30 minutes.'; end if;
  select coalesce(sum(prix),0) into b from notes where pid=auth.uid() and conf and not paid and payment_id is null and prix>0;
  if b<=0 then raise exception 'Rien à payer pour le moment'; end if;
  f := pay_fees(b);
  insert into payments(pid, montant, base, frais_om, frais_soutra, tel, provider)
    values(auth.uid(), (f->>'total')::int, b, (f->>'frais_om')::int, (f->>'frais_soutra')::int, nullif(regexp_replace(coalesce(phone,''),'\D','','g'),''), 'orange')
    returning id into pay;
  update notes set payment_id=pay where pid=auth.uid() and conf and not paid and payment_id is null and prix>0;
  return json_build_object('id', pay, 'montant', (f->>'total')::int, 'base', b, 'frais_om', (f->>'frais_om')::int, 'frais_soutra', (f->>'frais_soutra')::int);
end $$;

-- 7. Échec / annulation : libère aussi les paiements « En attente » refusés par Orange
create or replace function fail_payment(pay uuid, ref text) returns void language sql security definer set search_path=public as $$
  update payments set st='Échoué', provider_ref=coalesce(ref, provider_ref) where id=pay and st='En attente';
  update notes set payment_id=null where payment_id=pay and not paid $$;

-- 8. Droits
do $$ begin
  revoke all on function payment_quote() from public, anon; grant execute on function payment_quote() to authenticated;
  revoke all on function start_payment(text) from public, anon; grant execute on function start_payment(text) to authenticated;
  revoke all on function pay_fees(int) from public, anon, authenticated; grant execute on function pay_fees(int) to service_role;
  revoke all on function cfg_num(text,numeric) from public, anon, authenticated; grant execute on function cfg_num(text,numeric) to service_role;
  revoke all on function confirm_payment(uuid,text,integer) from public, anon, authenticated; grant execute on function confirm_payment(uuid,text,integer) to service_role;
  revoke all on function fail_payment(uuid,text) from public, anon, authenticated; grant execute on function fail_payment(uuid,text) to service_role;
end $$;

-- 9. Réglages : moyen de paiement + taux par défaut (si pas encore définis)
insert into settings(k, v) values('cfg', '{}'::jsonb) on conflict (k) do nothing;
update settings set v = jsonb_build_object('om_pct', 2, 'so_pct', 1, 'so_fixe', 0) || v || jsonb_build_object('pay', 'Orange Money') where k='cfg';
