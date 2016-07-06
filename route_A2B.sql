CREATE OR REPLACE FUNCTION public.route_A2B(
    IN startgeom geometry,
    IN endgeom geometry,
    IN weight text,
    OUT gid integer,
    OUT name text,
    OUT heading double precision,
    OUT length double precision,
    OUT geom geometry)
  RETURNS SETOF record AS
$BODY$
DECLARE
	srid integer;--图层srid
	searchDistance double precision;--搜索起点终点附近的到路线的有效距离
	startrec record;
	endrec   record;
	firstinfo boolean:=true;
	lastinfo boolean:=false;
	spiltcost double precision;
	querysql text;
    rec     record;
	startid	bigint;
	sql text;
BEGIN	
	--获取道路表对应的空间参考信息
	execute 'select srid from geometry_columns where f_table_name=''road''' into srid;
	if(srid=4326) then
		searchDistance:=0.04; --容差设置为4000米大约
	elsif(srid=3857) then
		searchDistance:=4000;
	end if;
	--通过对附近道路筛选，选出离起始点坐标最近的起始路段与结束路段
	select t.* from (select * from road r where st_intersects(r.geom,st_buffer(startgeom,searchDistance))) t order by st_distance(t.geom,startgeom) limit 1 into startrec;
	select t.* from (select * from road r where st_intersects(r.geom,st_buffer(endgeom,searchDistance))) t order by st_distance(t.geom,endgeom) limit 1 into endrec;
	--select a.* from road a where st_intersects(a.geom,ST_ClosestPoint(a.geom,startgeom)) into startrec;
	--select a.* from road a where st_intersects(a.geom,ST_ClosestPoint(a.geom,endgeom)) into endrec;
	--根据权重设置查询的语句
	IF weight='length' then
		querysql:='SELECT gid as id,source,target,'
        || 'lengthcost::float as cost,'
		|| 'reverse_lengthcost::float as reverse_cost FROM road';
	elsif weight='time' then 
		querysql:='SELECT gid as id,source,target,'
       	|| 'time::float as cost,'
		|| 'rev_time::float as reverse_cost FROM road';
	end if;
	--查询路径
	startid:=startrec.source;
	sql:= 'SELECT r.gid, r.geom, r.roadname,r.source,r.target, r.length FROM pgr_dijkstra('''||querysql||''','||startrec.source||','||endrec.target||',true,true) pd,road r where id2=r.gid order by pd.seq';
	FOR rec IN execute sql
    LOOP
		--如果起始点的snodeid与记录的sid不一致，反转
		IF ( startid != rec.source ) THEN
			rec.geom := ST_Reverse(rec.geom);
			startid := rec.source;
		ELSE
			startid := rec.target;
		END IF;
		gid     := rec.gid;
		name    := rec.roadname;
		if(firstinfo=true) then --在路径第一条时，判断路径与起始点的路径是否为同一路段
			if(rec.gid=startrec.gid) then --包含截取
				spiltcost:=ST_LineLocatePoint(startrec.geom,startgeom);
				length:=rec.length*(1-spiltcost);
				geom:=ST_LineSubstring(startrec.geom,spiltcost,1);
				SELECT degrees(ST_Azimuth(ST_StartPoint(geom),ST_EndPoint(geom))) INTO heading;
			else--不包含，补齐
				gid:= startrec.gid;
				name:= startrec.roadname;
				spiltcost:=ST_LineLocatePoint(startrec.geom,startgeom);
				length:=spiltcost*startrec.length;
				geom:=ST_LineSubstring(startrec.geom,0,spiltcost);
				SELECT degrees(ST_Azimuth(ST_StartPoint(geom),ST_EndPoint(geom))) INTO heading;
			end if;
			firstinfo:=false;
			return next;
			continue;
		end if;
		if(rec.gid=endrec.gid) then--结束路段和查询的路段包含，截取
			spiltcost:=ST_LineLocatePoint(endrec.geom,endgeom);
			length:=rec.length*spiltcost;
			geom:=ST_LineSubstring(endrec.geom,0,spiltcost);
			SELECT degrees(ST_Azimuth(ST_StartPoint(geom),ST_EndPoint(geom))) INTO heading;
			lastinfo:=true;
			return next;
		end if;
		SELECT degrees(ST_Azimuth(ST_StartPoint(rec.geom),ST_EndPoint(rec.geom))) INTO heading;
		length:= rec.length;
		geom:= rec.geom;
		RETURN NEXT;
    END LOOP;
	--处理终点线
	if(lastinfo=false) then 
		gid     := endrec.gid;
		name    := endrec.roadname;
		spiltcost:=ST_LineLocatePoint(endrec.geom,endgeom);
		length:=(1-spiltcost)*endrec.length;
		geom:=ST_LineSubstring(endrec.geom,spiltcost,1);
		SELECT degrees(ST_Azimuth(ST_StartPoint(geom),ST_EndPoint(geom))) INTO heading;
		return next;
	end if;
	RETURN;
END;
$BODY$
LANGUAGE 'plpgsql' VOLATILE STRICT;