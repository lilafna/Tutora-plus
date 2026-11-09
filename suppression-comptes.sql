-- =====================================================================
-- Tutora + : SUPPRESSION DE COMPTES PAR LE PROPRIÉTAIRE
-- À coller dans Supabase > SQL Editor puis "Run". Une seule fois suffit
-- (mais le relancer ne casse rien).
--
-- Ce que ça fait :
--  1. Ajoute la notion de "propriétaire" : un administrateur au-dessus des autres (toi).
--  2. Seul le propriétaire peut supprimer un compte, quel qu'il soit
--     (parent, répétiteur ou administrateur qu'il a nommé).
--  3. Personne ne peut supprimer, rétrograder ou "devenir" le propriétaire depuis le site.
--  4. Les tables sont réglées pour qu'une suppression ne bloque pas :
--     l'historique (séances passées, paiements) est gardé, le reste est nettoyé.
-- =====================================================================

-- 1. Colonne "propriétaire"
alter table profiles add column if not exists proprietaire boolean not null default false;

create or replace function is_owner() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from profiles where id=auth.uid() and role='admin' and proprietaire) $$;

-- 2. Garde-fou : depuis le site, personne ne touche au propriétaire
create or replace function guard_profiles() returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') then
    if tg_op='INSERT' then
      if new.proprietaire then raise exception 'Action non autorisée'; end if;
    else
      if new.proprietaire is distinct from old.proprietaire then
        raise exception 'Le propriétaire se désigne uniquement depuis Supabase';
      end if;
      if old.proprietaire and new.role is distinct from old.role then
        raise exception 'Le rôle du propriétaire ne peut pas être modifié';
      end if;
      if old.role='admin' and new.role is distinct from old.role and not is_owner() then
        raise exception 'Seul le propriétaire peut retirer un administrateur';
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists t_guard_profiles on profiles;
create trigger t_guard_profiles before insert or update on profiles for each row execute function guard_profiles();

-- 3. Liens entre tables : ce qui se passe quand un compte disparaît
--    "set null" = on garde la ligne (historique), sans le nom de la personne
--    "cascade"  = la ligne part avec le compte
do $$
declare r record; c record;
begin
  for r in select * from (values
      ('requests','pid','set null'), ('requests','rid','set null'),
      ('sessions','pid','set null'), ('sessions','rid','set null'),
      ('notes','pid','cascade'),     ('changes','asked_by','cascade'),
      ('tasks','rid','set null'),    ('payments','pid','set null')
    ) as v(tbl, col, act)
  loop
    for c in
      select con.conname from pg_constraint con
      join pg_attribute a on a.attrelid=con.conrelid and a.attnum=any(con.conkey)
      where con.contype='f' and con.conrelid=('public.'||r.tbl)::regclass and a.attname=r.col
    loop
      execute format('alter table public.%I drop constraint %I', r.tbl, c.conname);
    end loop;
    if r.act='set null' then
      execute format('alter table public.%I alter column %I drop not null', r.tbl, r.col);
    end if;
    execute format('alter table public.%I add constraint %I foreign key (%I) references public.profiles(id) on delete %s',
                   r.tbl, r.tbl||'_'||r.col||'_fkey', r.col, r.act);
  end loop;
end $$;

-- 4. La suppression elle-même
create or replace function delete_account(target uuid) returns void language plpgsql security definer set search_path=public as $$
declare t profiles;
begin
  if not is_owner() then raise exception 'Seul le propriétaire peut supprimer un compte'; end if;
  if target = auth.uid() then raise exception 'Vous ne pouvez pas supprimer votre propre compte'; end if;
  select * into t from profiles where id=target;
  if t.id is null then raise exception 'Compte introuvable'; end if;
  if t.proprietaire then raise exception 'Le compte propriétaire ne peut pas être supprimé'; end if;

  -- Répétiteur : ses séances à venir sont annulées, ses cours repartent vers l'équipe
  update sessions set st='Annulée' where rid=target and st in ('Prévue','À confirmer');
  update requests set rid=null, st='Nouvelle', motif='Répétiteur retiré : l''équipe va en proposer un autre'
   where rid=target and st in ('Envoyée','Acceptée');

  -- Parent : ses cours à lui seul sont annulés (un groupe ouvert continue pour les autres parents)
  update sessions s set st='Annulée' where s.pid=target and s.st in ('Prévue','À confirmer')
     and not exists(select 1 from enrollments e where e.qid=s.qid and e.pid<>target);
  update requests r set st='Annulée' where r.pid=target and r.st in ('Nouvelle','Envoyée')
     and not exists(select 1 from enrollments e where e.qid=r.id and e.pid<>target);
  update payments set st='Annulé' where pid=target and st='En attente';

  -- Messages de la personne (et de ses enfants)
  delete from messages where from_id=target or to_id=target
     or child_id in (select id from children where pid=target);

  -- Compte de connexion : supprime aussi le profil, les enfants, leurs devoirs et fiches
  delete from auth.users where id=target;
  delete from profiles where id=target;   -- au cas où le profil existait sans compte de connexion
end $$;
revoke all on function delete_account(uuid) from public, anon;
grant execute on function delete_account(uuid) to authenticated;

-- 5. Le propriétaire peut effacer la carte d'étudiant d'un compte supprimé
do $$ begin
  execute 'drop policy if exists st_del on storage.objects';
  execute $q$create policy st_del on storage.objects for delete to authenticated using(bucket_id='cartes' and public.is_owner())$q$;
exception when others then raise notice 'Règle de stockage non créée : %', sqlerrm;
end $$;

-- 6. TOI = le propriétaire
--    Remplace l'email ci-dessous par celui de TON compte administrateur si ce n'est pas le bon.
update profiles set proprietaire=true where email='lilafna224@gmail.com' and role='admin';
do $$ begin
  if not exists(select 1 from profiles where proprietaire) then
    raise notice 'ATTENTION : aucun propriétaire désigné. Vérifie l''email à l''étape 6 puis relance.';
  end if;
end $$;
