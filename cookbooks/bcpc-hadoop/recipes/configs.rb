# disable IPv6 (e.g. for HADOOP-8568)
case node["platform_family"]
  when "debian"
    %w{net.ipv6.conf.all.disable_ipv6
       net.ipv6.conf.default.disable_ipv6
       net.ipv6.conf.lo.disable_ipv6}.each do |param|
      sysctl_param param do
        value 1
        notifies :run, "bash[restart_networking]", :delayed
      end
    end

    bash "restart_networking" do
      code "service networking restart"
      action :nothing
    end
  else
   Chef::Log.warn "============ Unable to disable IPv6 for non-Debian systems"
end

# set vm.swapiness to 0 (to lessen swapping)
sysctl_param 'vm.swappiness' do
  value 0
end

%w{hadoop
  hbase
  hive
  oozie
  pig
  webhcat
  hcat
  hadoop-httpfs
  hive-hcatalog
  hue}.each do |w|
  directory "/etc/#{w}/conf.#{node.chef_environment}" do
    owner "root"
    group "root"
    mode 00755
    action :create
    recursive true
  end

  bash "update-#{w}-conf-alternatives" do
    code %Q{
     update-alternatives --install /etc/#{w}/conf #{w}-conf /etc/#{w}/conf.#{node.chef_environment} 50
     update-alternatives --set #{w}-conf /etc/#{w}/conf.#{node.chef_environment}
    }
  end
end

make_config('mysql-hive-password', secure_password)
make_config('oozie-keystore-password', secure_password)
make_config('mysql-hue-password', secure_password)
make_config('hue-session-key', secure_password)
make_config('mysql-oozie-password', secure_password)

#
#set up hadoop conf
#

package "bigtop-jsvc"

template "hadoop-detect-javahome" do
  path "/usr/lib/bigtop-utils/bigtop-detect-javahome"
  source "hdp_bigtop-detect-javahome.erb"
  owner "root"
  group "root"
  mode "0755"
end

hadoop_conf_files = %w{capacity-scheduler.xml
   core-site.xml
   hadoop-metrics2.properties
   hadoop-metrics.properties
   hadoop-policy.xml
   hdfs-site.xml
   log4j.properties
   mapred-site.xml
   slaves
   ssl-client.xml
   ssl-server.xml
   yarn-site.xml
   mapred.exclude
   dfs.exclude
  }
node[:bcpc][:hadoop][:hdfs][:HA] == true and hadoop_conf_files.insert(-1,"hdfs-site_HA.xml")

nn_hosts = get_namenodes()
node.default[:bcpc][:zookeeper][:servers] = get_nodes_for("zookeeper_server")
jn_hosts = get_nodes_for("journalnode")
rm_hosts = get_nodes_for("resource_manager")
hs_hosts = get_nodes_for("historyserver")
dn_hosts = get_nodes_for("datanode")
hb_hosts = get_nodes_for("hbase_master")
hive_hosts = get_nodes_for("hive_metastore")

hadoop_conf_files.each do |t|
   template "/etc/hadoop/conf/#{t}" do
     source "hdp_#{t}.erb"
     mode 0644
     variables(:nn_hosts => nn_hosts,
               :zk_hosts => node[:bcpc][:zookeeper][:servers],
               :jn_hosts => jn_hosts,
               :rm_hosts => rm_hosts,
               :dn_hosts => dn_hosts,
               :hs_hosts => hs_hosts,
               :mounts => node[:bcpc][:hadoop][:mounts])
   end
end

%w{yarn-env.sh
  hadoop-env.sh}.each do |t|
 template "/etc/hadoop/conf/#{t}" do
   source "hdp_#{t}.erb"
   mode 0644
   variables(:nn_hosts => nn_hosts,
             :zk_hosts => node[:bcpc][:zookeeper][:servers],
             :jn_hosts => jn_hosts,
             :mounts => node[:bcpc][:hadoop][:mounts],
             :nn_jmx_port => node[:bcpc][:hadoop][:namenode][:jmx][:port],
             :dn_jmx_port => node[:bcpc][:hadoop][:datanode][:jmx][:port]
   )
 end
end

#
# Set up hbase configs
#
%w{hadoop-metrics.properties
   hbase-env.sh
   hbase-policy.xml
   hbase-site.xml
   log4j.properties
   regionservers}.each do |t|
   template "/etc/hbase/conf/#{t}" do
     source "hb_#{t}.erb"
     mode 0644
     variables(:nn_hosts => nn_hosts,
               :zk_hosts => node[:bcpc][:zookeeper][:servers],
               :jn_hosts => jn_hosts,
               :rs_hosts => get_nodes_for("region_server"),
               :master_hosts => hb_hosts,
               :mounts => node[:bcpc][:hadoop][:mounts],
               :hbm_jmx_port => node[:bcpc][:hadoop][:hbase_master][:jmx][:port]
     )
  end
end

#
# Set up hive configs
#
%w{hive-exec-log4j.properties
   hive-log4j.properties
   hive-env.sh
   hive-site.xml }.each do |t|
   template "/etc/hive/conf/#{t}" do
     source "hv_#{t}.erb"
     mode 0644
     variables(:mysql_hosts => get_mysql_nodes.map{ |m| m.hostname },
               :zk_hosts => node[:bcpc][:zookeeper][:servers],
               :hive_hosts => hive_hosts)
  end
end

#
# Set up oozie configs
#
%w{
  oozie-env.sh
  oozie-site.xml
  adminusers.txt
  oozie-default.xml
  oozie-log4j.properties
  }.each do |t|
  template "/etc/oozie/conf/#{t}" do
    source "ooz_#{t}.erb"
    mode 0644
    variables(:mysql_hosts => get_mysql_nodes.map{ |m| m.hostname },
              :zk_hosts => node[:bcpc][:zookeeper][:servers],
              :hive_hosts => hive_hosts)
  end
end
link "/etc/oozie/conf.#{node.chef_environment}/hive-site.xml" do
  to "/etc/hive/conf.#{node.chef_environment}/hive-site.xml"
end
link "/etc/oozie/conf.#{node.chef_environment}/core-site.xml" do
  to "/etc/hadoop/conf.#{node.chef_environment}/core-site.xml"
end
link "/etc/oozie/conf.#{node.chef_environment}/yarn-site.xml" do
  to "/etc/hadoop/conf.#{node.chef_environment}/yarn-site.xml"
end

#
# HTTPFS and Hue configs
#
%w{
  httpfs-env.sh
  httpfs-log4j.properties
  httpfs-signature.secret
  httpfs-site.xml
   }.each do |t|
   template "/etc/hadoop-httpfs/conf/#{t}" do
     source "#{t}.erb"
     mode 0644
  end
end

link "/etc/hive-hcatalog/conf.#{node.chef_environment}/hive-site.xml" do
  to "/etc/hive/conf.#{node.chef_environment}/hive-site.xml"
end

#
# HUE Configs
#
if false
%w{
  hue.ini
  log4j.properties
  log.conf}.each do |t|
   template "/etc/hue/conf/#{t}" do
     source "hue_#{t}.erb"
     mode 0644
     variables(
               :zk_hosts => node[:bcpc][:zookeeper][:servers],
               :rm_hosts  => rm_hosts,
               :hive_hosts  => hive_hosts,
               :oozie_hosts  => get_nodes_for("oozie"),
               :httpfs_hosts => get_nodes_for("httpfs"),
               :hb_hosts  => hb_hosts)
  end
end
end

%w{openjdk-7-jdk zookeeper}.each do |pkg|
  package pkg do
    action :upgrade
  end
end
