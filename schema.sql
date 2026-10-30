-- =====================================================================
-- Tutora + : schéma Supabase COMPLET (version 2)
-- À coller dans Supabase > SQL Editor puis "Run".
-- Relançable sans risque : il crée ce qui manque et remplace les règles.
-- =====================================================================

-- ============ TABLES ============
create table if not exists profiles(id uuid primary key references auth.users on delete cascade, role text not null check(role in('parent','rep','admin')), nom text not null, tel text, email text, quartier text, mat text[], niv text[], dispo text, st text default 'attente', rdv jsonb, docs jsonb, created_at timestamptz default now());
create table if not exists children(id bigint generated always as identity primary key, pid uuid references profiles on delete cascade, prenom text not null, niveau text, a_telephone boolean default false, token uuid default gen_random_uuid());
create unique index if not exists children_token_idx on children(token);

-- Un "cours" : un répétiteur, un ou plusieurs enfants (individuel, groupe d'une même famille, groupe ouvert à plusieurs parents)
create table if not exists requests(id bigint generated always as identity primary key, pid uuid references profiles, enfant text, niveau text, mat text[], type text, quartier text, budget text, dispo text, exam boolean, st text default 'Nouvelle', rid uuid references profiles, created_at timestamptz default now());
alter table requests add column if not exists child_id bigint references children on delete set null; -- ancienne version
alter table requests add column if not exists grp_mode text check(grp_mode in('famille','ouvert'));
alter table requests add column if not exists code text unique;
alter table requests add column if not exists motif text;

-- Enfants inscrits dans un cours (prénom copié : le répétiteur ne voit jamais le lien secret de l'enfant)
create table if not exists enrollments(id bigint generated always as identity primary key, qid bigint not null references requests on delete cascade, child_id bigint not null references children on delete cascade, pid uuid not null references profiles on delete cascade, prenom text, niveau text, created_at timestamptz default now(), unique(qid, child_id));

create table if not exists sessions(id bigint generated always as identity primary key, qid bigint references requests, pid uuid references profiles, rid uuid references profiles, date date, heure time, st text default 'Prévue', fiche jsonb, conf boolean default false, pay text default 'Non payé');
alter table sessions add column if not exists mois text;

-- Fiche de séance PAR ENFANT : chaque parent ne voit que celle de son enfant
create table if not exists notes(id bigint generated always as identity primary key, sid bigint not null references sessions on delete cascade, child_id bigint not null references children on delete cascade, pid uuid not null references profiles, present boolean default true, notions text, niveau text, devoirs text, obs text, conf boolean default false, conf_at timestamptz, prix int not null default 0, paid boolean default false, payment_id uuid, created_at timestamptz default now(), unique(sid, child_id));

-- Demandes de report / d'annulation (accord des deux côtés)
create table if not exists changes(id bigint generated always as identity primary key, sid bigint not null references sessions on delete cascade, asked_by uuid not null default auth.uid() references profiles, kind text not null check(kind in('report','annulation')), new_date date, new_heure time, motif text, st text not null default 'En attente', answered_by uuid, created_at timestamptz default now());

-- Devoirs déposés par le répétiteur (photo ou document)
create table if not exists tasks(id bigint generated always as identity primary key, qid bigint not null references requests on delete cascade, child_id bigint references children on delete cascade, rid uuid not null default auth.uid() references profiles, titre text not null, consigne text, fichier text, fichier_nom text, echeance date, created_at timestamptz default now());
create table if not exists task_done(task_id bigint references tasks on delete cascade, child_id bigint references children on delete cascade, reponse text, done_at timestamptz default now(), primary key(task_id, child_id));

create table if not exists messages(id bigint generated always as identity primary key, from_id uuid default auth.uid(), to_id uuid, child_id bigint, txt text not null, created_at timestamptz default now());
create table if not exists reports(id bigint generated always as identity primary key, sid bigint references sessions, kind text check(kind in('avis','signal')), note int, txt text, by uuid default auth.uid(), st text default 'Ouvert');
create table if not exists settings(k text primary key, v jsonb);

-- Paiements : AUCUN utilisateur (ni parent, ni admin) ne peut les modifier. Seul le serveur de paiement le fait.
create table if not exists payments(id uuid primary key default gen_random_uuid(), pid uuid not null references profiles, montant int not null check(montant>0), tel text, st text not null default 'En attente', provider text default 'soutra', provider_ref text, created_at timestamptz default now(), paid_at timestamptz);

alter table profiles enable row level security; alter table children enable row level security; alter table requests enable row level security; alter table enrollments enable row level security; alter table sessions enable row level security; alter table notes enable row level security; alter table changes enable row level security; alter table tasks enable row level security; alter table task_done enable row level security; alter table messages enable row level security; alter table reports enable row level security; alter table settings enable row level security; alter table payments enable row level security;

-- ============ FONCTIONS D'AIDE (sans boucle entre règles) ============
create or replace function is_admin() returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;
-- Peut voir ce cours : admin, parent créateur, parent d'un enfant inscrit, répétiteur
create or replace function can_see_q(q bigint) returns boolean language sql stable security definer set search_path=public as $$
  select is_admin() or exists(select 1 from requests r where r.id=q and (r.pid=auth.uid() or r.rid=auth.uid())) or exists(select 1 from enrollments e where e.qid=q and e.pid=auth.uid()) $$;
-- Répétiteur ayant accepté ce cours
create or replace function is_rep_of_q(q bigint) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from requests r where r.id=q and r.rid=auth.uid() and r.st='Acceptée') $$;
-- Répétiteur d'un enfant (cours accepté)
create or replace function is_rep_of_child(c bigint) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from enrollments e join requests r on r.id=e.qid where e.child_id=c and r.rid=auth.uid() and r.st='Acceptée') $$;
create or replace function is_parent_of_child(c bigint) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from children where id=c and pid=auth.uid()) $$;
-- Deux personnes liées par un cours (pour voir le nom / téléphone de l'autre)
create or replace function linked_to(other uuid) returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from requests r where r.rid=other and (r.pid=auth.uid() or exists(select 1 from enrollments e where e.qid=r.id and e.pid=auth.uid())))
      or exists(select 1 from requests r where r.rid=auth.uid() and (r.pid=other or exists(select 1 from enrollments e where e.qid=r.id and e.pid=other))) $$;
create or replace function cfg_int(key text, def int) returns int language sql stable security definer set search_path=public as $$
  select coalesce((select (v->>key)::int from settings where k='cfg'), def) $$;
create or replace function nowgn() returns timestamp language sql stable as $$ select (now() at time zone 'Africa/Conakry') $$;

-- ============ RÈGLES D'ACCÈS ============
do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies where schemaname='public' loop
    execute format('drop policy if exists %I on public.%I', p.policyname, p.tablename);
  end loop; end $$;

create policy p_sel on profiles for select using(id=auth.uid() or is_admin() or linked_to(id));
create policy p_ins on profiles for insert with check(id=auth.uid() and role in('parent','rep') and st='attente');
create policy p_upd on profiles for update using(is_admin());

create policy c_all on children for all using(pid=auth.uid() or is_admin()) with check(pid=auth.uid() or is_admin());

create policy q_sel on requests for select using(can_see_q(id));
create policy q_upd on requests for update using(is_admin());        -- intervention de l'équipe
create policy e_sel on enrollments for select using(pid=auth.uid() or is_admin() or exists(select 1 from requests r where r.id=qid and r.rid=auth.uid()));
create policy e_del on enrollments for delete using(pid=auth.uid() or is_admin());

create policy s_sel on sessions for select using(can_see_q(qid));
create policy s_ins on sessions for insert with check(is_admin());
create policy s_upd on sessions for update using(is_admin());

create policy n_sel on notes for select using(pid=auth.uid() or is_admin() or exists(select 1 from sessions s where s.id=sid and s.rid=auth.uid()));

create policy g_sel on changes for select using(exists(select 1 from sessions s where s.id=sid and can_see_q(s.qid)));

create policy k_sel on tasks for select using(rid=auth.uid() or is_admin() or (child_id is null and can_see_q(qid)) or is_parent_of_child(child_id));
create policy k_ins on tasks for insert with check(rid=auth.uid() and is_rep_of_q(qid) and (echeance is null or echeance>=nowgn()::date) and (child_id is null or exists(select 1 from enrollments e where e.qid=tasks.qid and e.child_id=tasks.child_id)));
create policy k_del on tasks for delete using(rid=auth.uid() or is_admin());
create policy d_sel on task_done for select using(is_admin() or is_parent_of_child(child_id) or exists(select 1 from tasks t where t.id=task_id and t.rid=auth.uid()));

create policy m_sel on messages for select using(from_id=auth.uid() or to_id=auth.uid() or is_admin() or (child_id is not null and (is_parent_of_child(child_id) or is_rep_of_child(child_id))));
create policy m_ins on messages for insert with check(from_id=auth.uid() and (child_id is null or is_admin() or is_rep_of_child(child_id)));

create policy r_sel on reports for select using(by=auth.uid() or is_admin() or (kind='avis' and exists(select 1 from sessions s where s.id=reports.sid and s.rid=auth.uid())));
create policy r_ins on reports for insert with check(by=auth.uid() and exists(select 1 from notes n where n.sid=reports.sid and n.pid=auth.uid()));
create policy r_upd on reports for update using(is_admin());

create policy t_sel on settings for select using(true);
create policy t_all on settings for all using(is_admin()) with check(is_admin());

create policy y_sel on payments for select using(pid=auth.uid() or is_admin());   -- lecture seule, pour tous

-- Supprime d'abord les anciennes versions de ces fonctions (quelle que soit leur forme)
do $$ declare f regprocedure; begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace='public'::regnamespace and p.proname = any(array['check_dates','guard_notes','tutors','create_request','join_group','group_size','answer_request','plan_month','confirm_month','ask_change','answer_change','save_fiche','confirm_note','set_carte','start_payment','confirm_payment','fail_payment','child_view','child_send','child_task_done']) loop
    execute 'drop function '||f||' cascade';
  end loop; end $$;

-- ============ DATES VALIDES (aucune date passée) ============
create or replace function check_dates() returns trigger language plpgsql as $$
begin
  if tg_table_name='sessions' then
    if (tg_op='INSERT' or new.date is distinct from old.date or new.heure is distinct from old.heure) and new.st<>'Annulée'
       and (new.date < nowgn()::date or (new.date = nowgn()::date and new.heure < nowgn()::time)) then
      raise exception 'Date invalide : la séance ne peut pas être dans le passé';
    end if;
  elsif tg_table_name='changes' then
    if new.kind='report' and (new.new_date is null or new.new_heure is null or new.new_date < nowgn()::date or (new.new_date=nowgn()::date and new.new_heure < nowgn()::time)) then
      raise exception 'Date invalide : choisissez une date à venir';
    end if;
  elsif tg_table_name='profiles' then
    if new.rdv is not null and new.rdv is distinct from (case when tg_op='UPDATE' then old.rdv end) and (new.rdv->>'date')::date < nowgn()::date then
      raise exception 'Date de rendez-vous invalide';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists t_dates on sessions; create trigger t_dates before insert or update on sessions for each row execute function check_dates();
drop trigger if exists t_dates on changes;  create trigger t_dates before insert on changes for each row execute function check_dates();
drop trigger if exists t_dates on profiles; create trigger t_dates before insert or update on profiles for each row execute function check_dates();

-- ============ GARDE-FOU PAIEMENT ============
-- Les colonnes de paiement ne changent QUE dans les fonctions du serveur (jamais depuis l'appli, même pour un admin)
create or replace function guard_notes() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon','service_role') and (new.paid is distinct from old.paid or new.payment_id is distinct from old.payment_id or new.prix is distinct from old.prix) then
    raise exception 'Le paiement est validé automatiquement après le paiement Soutra Money';
  end if;
  return new;
end $$;
drop trigger if exists t_guard_notes on notes; create trigger t_guard_notes before update on notes for each row execute function guard_notes();
drop trigger if exists t_guard_sessions on sessions; drop function if exists guard_sessions() cascade;
drop trigger if exists t_guard_requests on requests; drop function if exists guard_requests() cascade;

-- ============ FONCTIONS DE L'APPLI ============
-- Liste publique des répétiteurs validés (sans téléphone, email ni carte)
create or replace function tutors() returns table(id uuid, nom text, quartier text, mat text[], niv text[], dispo text, note numeric, nb_avis bigint) language sql stable security definer set search_path=public as $$
  select p.id, p.nom, p.quartier, p.mat, p.niv, p.dispo, round(avg(r.note)::numeric,1), count(r.id)
  from profiles p left join sessions s on s.rid=p.id left join reports r on r.sid=s.id and r.kind='avis'
  where p.role='rep' and p.st='valide' group by p.id order by p.quartier, p.nom $$;

-- Le parent crée un cours et l'envoie directement au répétiteur choisi (ou laisse l'équipe choisir : rep = null)
create or replace function create_request(rep uuid, kids bigint[], typ text, mode text, mats text[], quart text, disp text, budg text, ex boolean) returns bigint language plpgsql security definer set search_path=public as $$
declare q bigint; k children; n int := 0;
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='parent') then raise exception 'Réservé aux parents'; end if;
  if coalesce(array_length(kids,1),0)=0 then raise exception 'Choisissez au moins un enfant'; end if;
  if coalesce(array_length(mats,1),0)=0 then raise exception 'Choisissez au moins une matière'; end if;
  if typ not in('Individuel','Groupe') then raise exception 'Type invalide'; end if;
  if typ='Individuel' and array_length(kids,1)<>1 then raise exception 'Un cours individuel concerne un seul enfant'; end if;
  if typ='Groupe' and mode not in('famille','ouvert') then raise exception 'Précisez le type de groupe'; end if;
  if typ='Groupe' and mode='famille' and array_length(kids,1)<2 then raise exception 'Un groupe familial demande au moins 2 de vos enfants'; end if;
  if array_length(kids,1)>6 then raise exception 'Un groupe compte 6 élèves au maximum'; end if;
  if rep is not null and not exists(select 1 from profiles where id=rep and role='rep' and st='valide') then raise exception 'Répétiteur non disponible'; end if;
  insert into requests(pid, rid, type, grp_mode, mat, quartier, dispo, budget, exam, st, code)
    values(auth.uid(), rep, typ, case when typ='Groupe' then mode end, mats, quart, disp, nullif(budg,''), coalesce(ex,false),
           case when rep is null then 'Nouvelle' else 'Envoyée' end,
           case when typ='Groupe' and mode='ouvert' then upper(substr(md5(random()::text),1,6)) end)
    returning id into q;
  for k in select * from children where id = any(kids) loop
    if k.pid<>auth.uid() then raise exception 'Enfant inconnu'; end if;
    insert into enrollments(qid, child_id, pid, prenom, niveau) values(q, k.id, auth.uid(), k.prenom, k.niveau); n := n+1;
  end loop;
  if n<>array_length(kids,1) then raise exception 'Enfant inconnu'; end if;
  update requests set enfant=(select string_agg(prenom, ', ') from enrollments where qid=q),
                      niveau=(select string_agg(distinct niveau, ', ') from enrollments where qid=q) where id=q;
  return q;
end $$;

-- Un autre parent rejoint un groupe ouvert avec le code reçu
create or replace function join_group(c text, kid bigint) returns bigint language plpgsql security definer set search_path=public as $$
declare r requests; k children;
begin
  select * into r from requests where code=upper(trim(c)) and type='Groupe' and grp_mode='ouvert';
  if r.id is null then raise exception 'Code de groupe introuvable'; end if;
  if r.st not in('Nouvelle','Envoyée','Acceptée') then raise exception 'Ce groupe est fermé'; end if;
  select * into k from children where id=kid and pid=auth.uid();
  if k.id is null then raise exception 'Enfant inconnu'; end if;
  if (select count(*) from enrollments where qid=r.id)>=6 then raise exception 'Le groupe est complet (6 élèves)'; end if;
  insert into enrollments(qid, child_id, pid, prenom, niveau) values(r.id, k.id, auth.uid(), k.prenom, k.niveau) on conflict do nothing;
  return r.id;
end $$;
-- Nombre d'élèves d'un groupe (sans montrer les autres enfants)
create or replace function group_size(q bigint) returns int language sql stable security definer set search_path=public as $$
  select case when can_see_q(q) then (select count(*)::int from enrollments where qid=q) end $$;

-- Le répétiteur accepte ou refuse un cours
create or replace function answer_request(q bigint, ok boolean, why text default null) returns void language plpgsql security definer set search_path=public as $$
begin
  update requests set st=case when ok then 'Acceptée' else 'Refusée par le répétiteur' end, motif=why
   where id=q and rid=auth.uid() and st='Envoyée';
  if not found then raise exception 'Demande introuvable'; end if;
end $$;

-- Le parent (créateur du cours) planifie TOUT le mois d'un coup ; le répétiteur confirme le mois en un clic
create or replace function plan_month(q bigint, m text, jours int[], h time) returns int language plpgsql security definer set search_path=public as $$
declare r requests; d date; d0 date; d1 date; n int := 0;
begin
  select * into r from requests where id=q;
  if r.id is null or not (r.pid=auth.uid() or is_admin()) then raise exception 'Seul le parent qui a créé le cours peut le planifier'; end if;
  if r.st<>'Acceptée' then raise exception 'Le répétiteur doit d''abord accepter le cours'; end if;
  if m !~ '^\d{4}-\d{2}$' then raise exception 'Mois invalide'; end if;
  d0 := (m||'-01')::date; d1 := (d0 + interval '1 month')::date;
  if d1 <= nowgn()::date then raise exception 'Ce mois est déjà passé'; end if;
  if coalesce(array_length(jours,1),0)=0 then raise exception 'Choisissez au moins un jour'; end if;
  if exists(select 1 from sessions where qid=q and mois=m and st in('À confirmer','Prévue')) then raise exception 'Ce mois est déjà planifié. Demandez un report pour changer une séance.'; end if;
  d := greatest(d0, nowgn()::date);
  while d < d1 loop
    if extract(isodow from d)::int = any(jours) and (d > nowgn()::date or h > nowgn()::time) then
      insert into sessions(qid, pid, rid, date, heure, st, mois) values(q, r.pid, r.rid, d, h, 'À confirmer', m); n := n+1;
    end if;
    d := d + 1;
  end loop;
  if n=0 then raise exception 'Aucune date à venir ce mois-ci avec ces jours'; end if;
  return n;
end $$;
create or replace function confirm_month(q bigint, m text, ok boolean) returns int language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if not exists(select 1 from requests where id=q and rid=auth.uid()) and not is_admin() then raise exception 'Non autorisé'; end if;
  if ok then update sessions set st='Prévue' where qid=q and mois=m and st='À confirmer';
  else delete from sessions where qid=q and mois=m and st='À confirmer'; end if;
  get diagnostics n = row_count; return n;
end $$;

-- Report ou annulation : demandé par un côté, accepté par l'autre. Impossible après la séance.
create or replace function ask_change(s bigint, k text, d date, h time, why text) returns bigint language plpgsql security definer set search_path=public as $$
declare x sessions; c bigint;
begin
  select * into x from sessions where id=s;
  if x.id is null or not (x.pid=auth.uid() or x.rid=auth.uid()) then raise exception 'Seuls le parent du cours et le répétiteur peuvent le demander'; end if;
  if x.st not in('Prévue','À confirmer') or exists(select 1 from notes where sid=s) then raise exception 'Séance déjà réalisée : plus d''annulation ni de report possible'; end if;
  if exists(select 1 from changes where sid=s and st='En attente') then raise exception 'Une demande est déjà en attente pour cette séance'; end if;
  if length(coalesce(trim(why),''))<3 then raise exception 'Indiquez le motif'; end if;
  insert into changes(sid, asked_by, kind, new_date, new_heure, motif) values(s, auth.uid(), k, d, h, trim(why)) returning id into c;
  return c;
end $$;
create or replace function answer_change(c bigint, ok boolean) returns void language plpgsql security definer set search_path=public as $$
declare g changes; x sessions;
begin
  select * into g from changes where id=c and st='En attente';
  if g.id is null then raise exception 'Demande introuvable'; end if;
  select * into x from sessions where id=g.sid;
  -- l'autre partie (ou l'équipe) répond ; on ne valide pas sa propre demande
  if not (is_admin() or (auth.uid() in (x.pid, x.rid) and auth.uid()<>g.asked_by)) then raise exception 'C''est à l''autre partie de répondre'; end if;
  if x.st not in('Prévue','À confirmer') or exists(select 1 from notes where sid=x.id) then raise exception 'Séance déjà réalisée'; end if;
  update changes set st=case when ok then 'Acceptée' else 'Refusée' end, answered_by=auth.uid() where id=c;
  if ok then
    if g.kind='annulation' then update sessions set st='Annulée' where id=x.id;
    else update sessions set date=g.new_date, heure=g.new_heure where id=x.id; end if;
  end if;
end $$;

-- Le répétiteur remplit la fiche : une ligne par enfant présent dans le cours. Seulement le jour même ou après.
create or replace function save_fiche(s bigint, fiches jsonb) returns void language plpgsql security definer set search_path=public as $$
declare x sessions; r requests; e enrollments; f jsonb; p int;
begin
  select * into x from sessions where id=s;
  if x.id is null or x.rid<>auth.uid() then raise exception 'Non autorisé'; end if;
  if x.st<>'Prévue' then raise exception 'Cette séance n''est pas à remplir'; end if;
  if x.date > nowgn()::date then raise exception 'La fiche se remplit le jour de la séance, pas avant'; end if;
  select * into r from requests where id=x.qid;
  p := case when r.type='Groupe' then cfg_int('grp',20000) else cfg_int('prix',25000) end;
  for e in select * from enrollments where qid=x.qid loop
    f := fiches->(e.child_id::text);
    if f is null then raise exception 'Fiche manquante pour %', e.prenom; end if;
    insert into notes(sid, child_id, pid, present, notions, niveau, devoirs, obs, prix)
      values(s, e.child_id, e.pid, coalesce((f->>'present')::boolean,true), f->>'notions', f->>'niveau', f->>'devoirs', f->>'obs',
             case when coalesce((f->>'present')::boolean,true) then p else 0 end);
  end loop;
  update sessions set st='Réalisée' where id=s;
end $$;

-- Le parent confirme la séance de SON enfant (rend la séance facturable)
create or replace function confirm_note(n bigint) returns void language plpgsql security definer set search_path=public as $$
begin
  update notes set conf=true, conf_at=now() where id=n and pid=auth.uid() and not conf;
  if not found then raise exception 'Séance introuvable'; end if;
end $$;

-- Le répétiteur enregistre sa carte d'étudiant envoyée après coup
create or replace function set_carte(path text) returns void language plpgsql security definer set search_path=public as $$
begin
  if auth.uid() is null or split_part(path,'/',1)<>auth.uid()::text then raise exception 'Chemin non autorisé'; end if;
  update profiles set docs=coalesce(docs,'{}'::jsonb)||jsonb_build_object('carte',path) where id=auth.uid() and role='rep';
end $$;

-- ============ PAIEMENT SOUTRA MONEY ============
-- 1. Le parent lance un paiement : le MONTANT est calculé ici, pas dans l'appli (impossible à trafiquer)
create or replace function start_payment(phone text) returns json language plpgsql security definer set search_path=public as $$
declare tot int; pay uuid;
begin
  if not exists(select 1 from profiles where id=auth.uid() and role='parent') then raise exception 'Réservé aux parents'; end if;
  -- libère les séances d'une ancienne tentative restée sans réponse
  update payments set st='Expiré' where pid=auth.uid() and st='En attente' and created_at < now() - interval '30 minutes';
  update notes set payment_id=null where pid=auth.uid() and not paid and payment_id in (select id from payments where st in('Expiré','Échoué'));
  if exists(select 1 from payments where pid=auth.uid() and st='En attente') then raise exception 'Un paiement est déjà en cours. Validez-le sur votre téléphone ou réessayez dans 30 minutes.'; end if;
  select coalesce(sum(prix),0) into tot from notes where pid=auth.uid() and conf and not paid and payment_id is null and prix>0;
  if tot<=0 then raise exception 'Rien à payer pour le moment'; end if;
  insert into payments(pid, montant, tel) values(auth.uid(), tot, regexp_replace(coalesce(phone,''),'\D','','g')) returning id into pay;
  update notes set payment_id=pay where pid=auth.uid() and conf and not paid and payment_id is null and prix>0;
  return json_build_object('id', pay, 'montant', tot);
end $$;

-- 2. Appelée UNIQUEMENT par le serveur (Edge Function avec la clé secrète) quand Soutra Money confirme le paiement
create or replace function confirm_payment(pay uuid, ref text, amount int) returns text language plpgsql security definer set search_path=public as $$
declare p payments;
begin
  select * into p from payments where id=pay for update;
  if p.id is null then raise exception 'Paiement inconnu'; end if;
  if p.st='Payé' then return 'déjà payé'; end if;               -- Soutra peut renvoyer la notification plusieurs fois
  if amount is distinct from p.montant then
    update payments set st='Échoué', provider_ref=ref where id=pay; return 'montant incorrect';
  end if;
  update payments set st='Payé', provider_ref=ref, paid_at=now() where id=pay;
  update notes set paid=true where payment_id=pay;
  return 'ok';
end $$;
create or replace function fail_payment(pay uuid, ref text) returns void language sql security definer set search_path=public as $$
  update payments set st='Échoué', provider_ref=ref where id=pay and st='En attente';
  update notes set payment_id=null where payment_id=pay and not paid $$;

-- ============ ESPACE ÉLÈVE (lien / QR code, sans compte) ============
create or replace function child_view(tok uuid) returns json language plpgsql stable security definer set search_path=public as $$
declare c children; qs bigint[];
begin
  select * into c from children where token=tok;
  if c.id is null then return null; end if;
  select coalesce(array_agg(qid),'{}') into qs from enrollments where child_id=c.id;
  return json_build_object(
    'child', json_build_object('prenom', c.prenom, 'niveau', c.niveau),
    'cours', coalesce((select json_agg(json_build_object('q', r.id, 'rep', p.nom, 'mat', r.mat, 'type', r.type)) from requests r left join profiles p on p.id=r.rid where r.id=any(qs) and r.st='Acceptée'), '[]'::json),
    'sessions', coalesce((select json_agg(json_build_object('date', s.date, 'heure', s.heure, 'st', s.st, 'rep', p.nom,
        'note', (select json_build_object('present', n.present, 'notions', n.notions, 'niveau', n.niveau, 'devoirs', n.devoirs, 'obs', n.obs) from notes n where n.sid=s.id and n.child_id=c.id))
        order by s.date, s.heure) from sessions s left join profiles p on p.id=s.rid where s.qid=any(qs) and s.st in('Prévue','Réalisée')), '[]'::json),
    'tasks', coalesce((select json_agg(json_build_object('id', t.id, 'titre', t.titre, 'consigne', t.consigne, 'fichier', t.fichier, 'fichier_nom', t.fichier_nom, 'echeance', t.echeance, 'rep', p.nom,
        'fait', d.done_at is not null, 'reponse', d.reponse) order by t.created_at desc)
        from tasks t left join profiles p on p.id=t.rid left join task_done d on d.task_id=t.id and d.child_id=c.id
        where t.qid=any(qs) and (t.child_id is null or t.child_id=c.id)), '[]'::json),
    'messages', coalesce((select json_agg(json_build_object('txt', m.txt, 't', m.created_at, 'mine', m.from_id is null, 'rep', p.nom) order by m.created_at)
        from messages m left join profiles p on p.id=coalesce(m.from_id, m.to_id) where m.child_id=c.id), '[]'::json));
end $$;

create or replace function child_send(tok uuid, t text, q bigint default null) returns void language plpgsql security definer set search_path=public as $$
declare c children; rep uuid;
begin
  select * into c from children where token=tok;
  if c.id is null then raise exception 'Lien invalide'; end if;
  if length(coalesce(trim(t),''))=0 or length(t)>1000 then raise exception 'Message vide ou trop long'; end if;
  select r.rid into rep from requests r join enrollments e on e.qid=r.id where e.child_id=c.id and r.st='Acceptée' and (q is null or r.id=q) order by r.id desc limit 1;
  if rep is null then raise exception 'Pas encore de répétiteur'; end if;
  insert into messages(from_id, to_id, child_id, txt) values(null, rep, c.id, trim(t));
end $$;

create or replace function child_task_done(tok uuid, task bigint, rep text) returns void language plpgsql security definer set search_path=public as $$
declare c children;
begin
  select * into c from children where token=tok;
  if c.id is null then raise exception 'Lien invalide'; end if;
  if not exists(select 1 from tasks t join enrollments e on e.qid=t.qid where t.id=task and e.child_id=c.id and (t.child_id is null or t.child_id=c.id)) then raise exception 'Devoir introuvable'; end if;
  insert into task_done(task_id, child_id, reponse) values(task, c.id, left(rep, 2000))
    on conflict (task_id, child_id) do update set reponse=excluded.reponse, done_at=now();
end $$;

-- ============ DROITS D'EXÉCUTION ============
drop function if exists child_send(uuid, text);
do $$ declare f text; begin
  foreach f in array array['tutors()','create_request(uuid,bigint[],text,text,text[],text,text,text,boolean)','join_group(text,bigint)','group_size(bigint)','answer_request(bigint,boolean,text)','plan_month(bigint,text,integer[],time)','confirm_month(bigint,text,boolean)','ask_change(bigint,text,date,time,text)','answer_change(bigint,boolean)','save_fiche(bigint,jsonb)','confirm_note(bigint)','set_carte(text)','start_payment(text)'] loop
    execute 'revoke all on function '||f||' from public, anon'; execute 'grant execute on function '||f||' to authenticated';
  end loop;
  foreach f in array array['child_view(uuid)','child_send(uuid,text,bigint)','child_task_done(uuid,bigint,text)'] loop
    execute 'revoke all on function '||f||' from public'; execute 'grant execute on function '||f||' to anon, authenticated';
  end loop;
  -- Paiement : seul le serveur (service_role). Ni les parents, ni les administrateurs.
  foreach f in array array['confirm_payment(uuid,text,integer)','fail_payment(uuid,text)'] loop
    execute 'revoke all on function '||f||' from public, anon, authenticated'; execute 'grant execute on function '||f||' to service_role';
  end loop;
end $$;

-- ============ STOCKAGE ============
-- Cartes d'étudiant : privé
-- Chaque étape est protégée : si Supabase refuse une règle de stockage, le reste du script passe quand même
-- et un message (NOTICE) l'indique. Dans ce cas, voir la section « Stockage » du mode d'emploi.
do $$
declare cmd text;
begin
  foreach cmd in array array[
    $q$insert into storage.buckets(id,name,public) values('cartes','cartes',false) on conflict (id) do nothing$q$,
    $q$insert into storage.buckets(id,name,public) values('devoirs','devoirs',true) on conflict (id) do update set public=true$q$,
    $q$drop policy if exists st_ins on storage.objects$q$,
    $q$drop policy if exists st_sel on storage.objects$q$,
    $q$drop policy if exists st_upd on storage.objects$q$,
    $q$drop policy if exists dv_ins on storage.objects$q$,
    $q$create policy st_ins on storage.objects for insert to authenticated with check(bucket_id='cartes' and (storage.foldername(name))[1]=auth.uid()::text)$q$,
    $q$create policy st_sel on storage.objects for select to authenticated using(bucket_id='cartes' and ((storage.foldername(name))[1]=auth.uid()::text or public.is_admin()))$q$,
    $q$create policy st_upd on storage.objects for update to authenticated using(bucket_id='cartes' and (storage.foldername(name))[1]=auth.uid()::text)$q$,
    $q$create policy dv_ins on storage.objects for insert to authenticated with check(bucket_id='devoirs' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.profiles where id=auth.uid() and role='rep' and st='valide'))$q$
  ] loop
    begin
      execute cmd;
    exception when others then
      raise notice 'Stockage non modifié (% ) : %', sqlerrm, left(cmd, 60);
    end;
  end loop;
end $$;

-- ============ PREMIER ADMINISTRATEUR ============
-- Après avoir créé le compte d'Ismaël dans Authentication > Users, lancer :
-- insert into profiles(id,role,nom,email) select id,'admin','Ismaël Barry',email from auth.users where email='lilafna224@gmail.com' on conflict (id) do update set role='admin';
