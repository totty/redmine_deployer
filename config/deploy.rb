# -*- coding: utf-8 -*-
set :application,      "redmine"

# scm
set :scm,               :subversion
set :scm_verbose,       false
set :repository,        "http://svn.redmine.org/redmine/branches/2.2-stable"

# default は, tar だが mac 標準の tar は bsdtar で gnutar ではないので zip にする
set :copy_compression,  :zip
set :copy_strategy,     :export
set :copy_exclude,      ['.git', '.svn', '**/.svn']
set :copy_cache,        true

# deploy
set :deploy_via,        :checkout
set :deploy_to,         "/var/#{application}"
set :deploy_env,        "production"
set :rails_env,         "production"
set :keep_releases,     3              # deploy:cleanup でも残る世代数

# # passenger-recipesの設定
# set :target_os,    :centos
# set :apache_user,  "apache"
# set :apache_group, "apache"

# roles
role :web, "192.168.0.2"
role :app, "192.168.0.2"
role :db , "192.168.0.2", :primary => true

# ssh
set :user, 'root'
set :password, 'password'
# set :user do
#   Capistrano::CLI.ui.ask('SSH User: ')
# end
# set :password do
#   Capistrano::CLI.password_prompt('SSH Password: ')
# end
set :ssh_options, {
  :forward_agent => true,
  :port          => 22,
#  :keys          => '/path/to/private_key'    # 公開鍵認証方式の場合
}
set :use_sudo,    false
default_run_options[:pty] = true

# rails3.0 以下のディレクトリ構成のエラーを無視する
set :normalize_asset_timestamps, false

# bundler
set :bundle_dir,        "./vendor/bundle"
set :bundle_flags,      "--quiet"
# set :bundle_without,    [:development, :test, :js_engine, :assets, :postgresql, :sqlite]
# set :bundle_without,    [:development, :test, :postgresql, :sqlite]
set :bundle_without,    [:development, :test, :postgresql, :mysql]

namespace :deploy do
  task :finished_setup_message do
    message =<<-EOS

deploy:setup に成功しました。
次に "/etc/httpd/conf.d/passenger.conf" などのapache設定ファイルを確認してください。

    <VirtualHost *:80>
      ServerName www.yourhost.com
      DocumentRoot /var/#{application}/current/public
      RailsEnv #{rails_env}
      <Directory /var/#{application}/current/public>
         AllowOverride all
         Options -MultiViews
      </Directory>
    </VirtualHost>

変更が完了したら、deploy:cold を実行してください。

    EOS
    puts message
  end

  task :precompile, :roles => [fetch(:role, :app)] do
    run "cd #{latest_release}/ && rake assets:precompile"
  end

  task :setup_database_yaml, :roles => [fetch(:role, :app)] do
    # database.yml だけは、手元のファイルをアップロード
    put(IO.read("config/database.yml"), "#{latest_release}/config/database.yml", :via => :scp, :mode => 0644)
  end

  after "deploy:update", :except => { :no_release => true } do
    cleanup
  end

  # deploy:startなどを上書き
  task(:start)   { httpd.start }
  task(:stop)    { httpd.stop }
  task(:restart) { httpd.restart }
end


namespace :db do
  def database_exists?
    exists = false
    show_db = <<-SQL
      show databases;
    SQL
    run "mysql --user=root --password= --execute=\"#{show_db}\"" do |channel, stream, data|
      exists = exists || data.include?("redmine")
    end
    puts "db exists = #{exists}"
    exists
  end

  task :create, :roles => [:db], :only => { :primary => true } do
    if database_exists?
      run "echo 'database exists.'"
    else
      run "cd #{current_path} && bundle exec rake RAILS_ENV=#{deploy_env} db:create"

      # ## (for MySQL)
      # ## ユーザ作成があるのでDBのCreateは個別にやりたい場合
      # create_sql = <<-SQL
      #   create database redmine character set utf8;
      # SQL
      # grant_sql = <<-SQL
      #   grant all privileges on *.* to 'root'@'%' identified by '' with grant option;
      # SQL
      # run "mysql --user=root --password= --execute=\"#{create_sql}\""
      # run "mysql --user=root --password= --execute=\"#{grant_sql}\""
    end
  end

  task :generate_secret_token, :roles => [:db], :only => { :primary => true } do
    run "cd #{current_path} && bundle exec rake RAILS_ENV=#{deploy_env} generate_secret_token"
  end

  task :redmine_load_data, :roles => [:db], :only => { :primary => true } do
    run "cd #{current_path} && bundle exec rake RAILS_ENV=#{deploy_env} REDMINE_LANG=ja redmine:load_default_data"
  end
end

# 以下の流れを踏まえた上で before/after を設定します
# ・deploy:cold
# ・deploy:update
#   == transaction: start ==
#   ・deploy:update_code
#   ・bundle install (opt)
#   ・deploy:finalize_update
#   ・deploy:create_symlink
#   == transaction: finish ==
# ・deploy:migrate
# ・deploy:start

after  "deploy:setup",           "deploy:finished_setup_message"
# after  "deploy:finalize_update", "deploy:precompile"
before "deploy:create_symlink",  "deploy:setup_database_yaml"

## see http://www.redmine.org/projects/redmine/wiki/RedmineInstall
# before "deploy:migrate",         "db:create"                # sqliteならcreate不要
before "deploy:migrate",         "db:generate_secret_token"
after  "deploy:migrate",         "db:redmine_load_data"


# apache & passenger
namespace :httpd do
  set :httpd_bin_path,  "/usr/sbin/apachectl"
  set :httpd_access_log_path, "/var/log/httpd/access_log"
  set :httpd_error_log_path,  "/var/log/httpd/error_log"

  %w(start stop restart graceful status fullstatus configtest).each do |command|
    desc "httpd #{command}"
    task(command, :roles => [fetch(:role, :web)]) do
      run "#{sudo} #{httpd_bin_path} #{command}", :pty => true
    end
  end

  task :graceful_stop, roles => [fetch(:role, :web)] do
    run "#{sudo} #{httpd_bin_path} graceful-stop", :pty => true
  end

  # apache:web:diable/enable
  namespace :web do
    desc "apache web disable"
    task(:disable) { deploy.web.disable }
    desc "apache web enable"
    task(:enable) { deploy.web.enable }
  end

  # log
  namespace :tail do
    task :access_log do
      stream("#{sudo} tail -f #{httpd_access_log_path}")
    end
    task :error_log do
      stream("#{try_sudo} tail -f #{httpd_error_log_path}")
    end
    task :rails_log, :roles => [fetch(:role, :app)] do
      stream("#{try_sudo} tail -f #{current_path}/log/#{rails_env}.log")
    end
  end
end

# process monitor
namespace :process do
  desc "uptime, free, df"
  task :monitor, :roles => :web do
    run "uptime"
    run "free -m"
    run "df -h"
  end

  # process 確認
  %w(httpd).each do |process|
    desc "ps | grep aux #{process}"
    task(process, :roles => [fetch(:role, :web)]) do
      run "ps axu | grep #{process}", :pty => false
    end
  end
end


# capistrano force stop for 'ctl+c'
Signal.trap(:INT) do
  abort "\n[cap] Inturrupted..."
end
