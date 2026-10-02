create schema if not exists amarelinho_private;
revoke all on schema amarelinho_private from public;
grant usage on schema amarelinho_private to anon,authenticated;
alter table public.orders add column customer_user_id uuid references auth.users(id);
create table public.club_members(user_id uuid primary key references auth.users(id),points integer not null default 0,created_at timestamptz not null default now());
create table public.club_history(id bigint generated always as identity primary key,user_id uuid not null references auth.users(id),order_id bigint references public.orders(id),points integer not null,description text not null,created_at timestamptz not null default now());
create unique index club_order_credit on public.club_history(order_id) where description='Compra concluída';
create table public.club_vouchers(id uuid primary key default gen_random_uuid(),user_id uuid not null references auth.users(id),reward_name text not null,points_cost integer not null,discount_value numeric not null default 0,status text not null default 'disponivel' check(status in ('disponivel','utilizado')),created_at timestamptz not null default now(),used_at timestamptz);
alter table public.club_members enable row level security;
alter table public.club_history enable row level security;
alter table public.club_vouchers enable row level security;
create policy own_member on public.club_members for select to authenticated using(user_id=(select auth.uid()));
create policy own_history on public.club_history for select to authenticated using(user_id=(select auth.uid()));
create policy own_vouchers on public.club_vouchers for select to authenticated using(user_id=(select auth.uid()) or public.is_staff());
grant select on public.club_members,public.club_history,public.club_vouchers to authenticated;
revoke insert,update,delete on public.club_members,public.club_history,public.club_vouchers from anon,authenticated;
-- All privileged mutations stay in a non-exposed schema; wrappers are invokers.
create function amarelinho_private.place_order(p_name text,p_phone text,p_type public.order_type,p_address text,p_items jsonb) returns table(id bigint,tracking_token uuid) language plpgsql security definer set search_path='' as $$
declare oid bigint; tok uuid; it jsonb; p public.products; qty integer; total_price numeric:=0; uid uuid:=auth.uid();
begin
 if coalesce(length(trim(p_name)),0)<2 or length(trim(p_name))>120 or coalesce(length(regexp_replace(p_phone,'[^0-9]','','g')),0) not between 10 and 13 then raise exception 'Informe nome e WhatsApp válidos'; end if;
 if p_type='entrega' and length(trim(coalesce(p_address,'')))<8 then raise exception 'Informe o endereço completo'; end if;
 if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 50 then raise exception 'Carrinho inválido'; end if;
 insert into public.orders(customer_name,customer_phone,type,address,total,customer_user_id) values(trim(p_name),p_phone,p_type,p_address,0,uid) returning orders.id,orders.tracking_token into oid,tok;
 for it in select value from jsonb_array_elements(p_items) loop
 qty:=(it->>'quantity')::integer;
 if qty is null or qty not between 1 and 20 then raise exception 'Quantidade inválida'; end if;
 select * into p from public.products where products.id=(it->>'product_id')::bigint and active for share;
 if not found or p.price is null or p.price<=0 then raise exception 'Produto indisponível'; end if;
 total_price:=total_price+p.price*qty;
 insert into public.order_items(order_id,product_id,product_name,quantity,unit_price) values(oid,p.id,p.name,qty,p.price);
 end loop;
 update public.orders set total=total_price where orders.id=oid;
 if uid is not null then insert into public.club_members(user_id) values(uid) on conflict do nothing; end if;
 return query select oid,tok;
end $$;
create function public.place_order(p_name text,p_phone text,p_type public.order_type,p_address text,p_items jsonb) returns table(id bigint,tracking_token uuid) language sql security invoker set search_path='' as $$select * from amarelinho_private.place_order(p_name,p_phone,p_type,p_address,p_items)$$;
revoke all on function amarelinho_private.place_order(text,text,public.order_type,text,jsonb),public.place_order(text,text,public.order_type,text,jsonb) from public;
grant execute on function amarelinho_private.place_order(text,text,public.order_type,text,jsonb),public.place_order(text,text,public.order_type,text,jsonb) to anon,authenticated;
-- Disable old unvalidated submission once the atomic path is installed.
revoke execute on function public.create_customer_order(text,text,public.order_type,text,numeric) from public,anon,authenticated;
drop policy public_create_orders on public.orders;
drop policy public_create_order_items on public.order_items;
create function amarelinho_private.credit_club() returns trigger language plpgsql security definer set search_path='' as $$
declare pts integer;
begin
 if new.customer_user_id is null then return new; end if;
 insert into public.club_members(user_id) values(new.customer_user_id) on conflict do nothing;
 if new.status='finalizado' and old.status is distinct from 'finalizado' then
 pts:=floor(coalesce(new.total,0));
 if pts>0 then
 insert into public.club_history(user_id,order_id,points,description) values(new.customer_user_id,new.id,pts,'Compra concluída') on conflict do nothing;
 if found then update public.club_members set points=points+pts where user_id=new.customer_user_id; end if;
 end if;
 elsif new.status='cancelado' and old.status is distinct from 'cancelado' then
 select points into pts from public.club_history where order_id=new.id and description='Compra concluída';
 if pts is not null and not exists(select 1 from public.club_history where order_id=new.id and description='Cancelamento da compra') then
 insert into public.club_history(user_id,order_id,points,description) values(new.customer_user_id,new.id,-pts,'Cancelamento da compra');
 update public.club_members set points=points-pts where user_id=new.customer_user_id;
 end if;
 end if; return new;
end $$;
revoke all on function amarelinho_private.credit_club() from public,anon,authenticated;
create trigger credit_club after update of status on public.orders for each row execute function amarelinho_private.credit_club();
create function amarelinho_private.redeem_reward(p_reward_id bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); balance integer; r public.loyalty_rewards; voucher uuid;
begin
 if uid is null then raise exception 'Entre na sua conta'; end if;
 insert into public.club_members(user_id) values(uid) on conflict do nothing;
 select points into balance from public.club_members where user_id=uid for update;
 select * into r from public.loyalty_rewards where id=p_reward_id and active for share;
 if not found then raise exception 'Recompensa indisponível'; end if;
 if balance<r.points_cost then raise exception 'Pontos insuficientes'; end if;
 update public.club_members set points=points-r.points_cost where user_id=uid;
 insert into public.club_history(user_id,points,description) values(uid,-r.points_cost,'Resgate: '||r.name);
 insert into public.club_vouchers(user_id,reward_name,points_cost,discount_value) values(uid,r.name,r.points_cost,r.discount_value) returning id into voucher;
 return voucher;
end $$;
create function public.redeem_reward(p_reward_id bigint) returns uuid language sql security invoker set search_path='' as $$select amarelinho_private.redeem_reward(p_reward_id)$$;
create function amarelinho_private.use_club_voucher(p_code uuid) returns text language plpgsql security definer set search_path='' as $$
declare result text;
begin
 if auth.uid() is null or not public.is_staff() then raise exception 'Acesso restrito à equipe'; end if;
 update public.club_vouchers set status='utilizado',used_at=now() where id=p_code and status='disponivel' returning reward_name into result;
 if result is null then raise exception 'Código inválido ou já utilizado'; end if;
 return result;
end $$;
create function public.use_club_voucher(p_code uuid) returns text language sql security invoker set search_path='' as $$select amarelinho_private.use_club_voucher(p_code)$$;
revoke all on function amarelinho_private.redeem_reward(bigint),public.redeem_reward(bigint),amarelinho_private.use_club_voucher(uuid),public.use_club_voucher(uuid) from public;
grant execute on function amarelinho_private.redeem_reward(bigint),public.redeem_reward(bigint),amarelinho_private.use_club_voucher(uuid),public.use_club_voucher(uuid) to authenticated;
alter function public.touch_order() set search_path='';
revoke execute on function public.credit_loyalty_points() from public,anon,authenticated;
revoke all on public.club_members,public.club_history,public.club_vouchers from anon;
revoke all on function public.redeem_reward(bigint),amarelinho_private.redeem_reward(bigint),public.use_club_voucher(uuid),amarelinho_private.use_club_voucher(uuid) from anon;
