-- Tutora + : schéma Supabase. À coller dans SQL Editor puis "Run".
create table profiles(id uuid primary key references auth.users on delete cascade, role text not null check(role in('parent','rep','admin')), nom text not null, tel text, email text, quartier text, mat text[], niv text[], dispo text, st text default 'attente', rdv jsonb, docs jsonb, created_at timestamptz default now());
create table children(id bigint generated always as identity primary key, pid uuid references profiles on delete cascade, prenom text not null, niveau text, a_telephone boolean default false, token uuid default gen_random_uuid());
create table requests(id bigint generated always as identity primary key, pid uuid references profiles, enfant text, niveau text, mat text[], type text, quartier text, budget text, dispo text, exam boolean, st text default 'Nouvelle', rid uuid references profiles, created_at timestamptz default now());
create table sessions(id bigint generated always as identity primary key, qid bigint references requests, pid uuid references profiles, rid uuid references profiles, date date, heure time, st text default 'Prévue', fiche jsonb, conf boolean default false, pay text default 'Non payé');
create table messages(id bigint generated always as identity primary key, from_id uuid default auth.uid(), to_id uuid, child_id bigint, txt text not null, created_at timestamptz default now());
create table reports(id bigint generated always as identity primary key, sid bigint references sessions, kind text check(kind in('avis','signal')), note int, txt text, by uuid default auth.uid(), st text default 'Ouvert');
create table settings(k text primary key, v jsonb);

create function is_admin() returns boolean language sql security definer set search_path=public as $$ select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;
alter table profiles enable row level security; alter table children enable row level security; alter table requests enable row level security; alter table sessions enable row level security; alter table messages enable row level security; alter table reports enable row level security; alter table settings enable row level security;

create policy p_sel on profiles for select using(id=auth.uid() or is_admin() or exists(select 1 from sessions s where (s.pid=auth.uid() and s.rid=profiles.id) or (s.rid=auth.uid() and s.pid=profiles.id)));
create policy p_ins on profiles for insert with check(id=auth.uid() and role in('parent','rep') and st='attente');
create policy p_upd on profiles for update using(is_admin());
create policy c_all on children for all using(pid=auth.uid() or is_admin()) with check(pid=auth.uid() or is_admin());
create policy q_sel on requests for select using(pid=auth.uid() or rid=auth.uid() or is_admin());
create policy q_ins on requests for insert with check(pid=auth.uid());
create policy q_upd on requests for update using(is_admin() or rid=auth.uid());
create policy s_sel on sessions for select using(pid=auth.uid() or rid=auth.uid() or is_admin());
create policy s_ins on sessions for insert with check(is_admin());
create policy s_upd on sessions for update using(pid=auth.uid() or rid=auth.uid() or is_admin());
create policy m_sel on messages for select using(from_id=auth.uid() or to_id=auth.uid() or is_admin() or exists(select 1 from children c where c.id=messages.child_id and c.pid=auth.uid()));
create policy m_ins on messages for insert with check(from_id=auth.uid());
create policy r_sel on reports for select using(by=auth.uid() or is_admin());
create policy r_ins on reports for insert with check(by=auth.uid());
create policy r_upd on reports for update using(is_admin());
create policy t_sel on settings for select using(true);
create policy t_all on settings for all using(is_admin()) with check(is_admin());

-- Stockage privé des cartes d’étudiant
insert into storage.buckets(id,name,public) values('cartes','cartes',false);
create policy st_ins on storage.objects for insert to authenticated with check(bucket_id='cartes' and (storage.foldername(name))[1]=auth.uid()::text);
create policy st_sel on storage.objects for select to authenticated using(bucket_id='cartes' and ((storage.foldername(name))[1]=auth.uid()::text or is_admin()));

-- Après avoir créé le compte d’Ismaël dans Authentication > Users, lancer :
-- insert into profiles(id,role,nom,email) select id,'admin','Ismaël Barry',email from auth.users where email='lilafna224@gmail.com';
