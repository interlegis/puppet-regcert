# init.pp

class regcert ( $regcert_dir      = '/srv/regcert',
                $regcert_data_dir = '/srv/regcert_data',
                $regcert_venv_dir = '/srv/.virtualenvs/regcert',
                $regcert_vhost    = 'localhost',
                $secret_key,
                $allowed_hosts    = 'localhost',
                $dbuser           = 'regcert',
                $dbpw,
                $dbhost           = 'localhost',
                $dbport           = '5432',
                $dbname           = 'regcert',
  ) {

  include supervisor

  Exec {
    path => '/usr/bin:/usr/sbin:/bin:/usr/local/bin',
  }

  group { 'regcert':
    ensure => 'present',
  }

  user { 'regcert':
    ensure => 'present',
    system => true,
    gid => 'regcert',
    require => Group['regcert']
  }


  $package_deps = ['git', 'supervisor', 'npm', 'gettext', 'libpq-dev' ]

  package { $package_deps:
    ensure => installed,
  }


  vcsrepo { $regcert_dir:
    ensure   => present,
    revision => 'stable/0.1.x',
    provider => git,
    source   => 'https://github.com/interlegis/regcert',
    notify   => [
      Exec['collectstatic'],
      Exec['compilemessages'],
      Exec['migrate'],
      Python::Requirements["${regcert_dir}/requirements/prod-requirements.txt"],
      Service['supervisor'],
    ],
    require  => [
      Package['git'],
    ],
  }

  file { "${regcert_dir}/bin/run_regcert":
    mode => 775,
    require => Vcsrepo[$regcert_dir],
  }

  file { $regcert_dir:
    mode => 775,
    require => Vcsrepo[$regcert_dir],
  }

  file { "${regcert_dir}/src/.env":
    mode => 444,
    content => template('regcert/env.erb'),
    require => Vcsrepo[$regcert_dir],
  }


# Bower #######################################################################


  package { 'bower':
    name            => 'bower',
    provider        => 'npm',
    install_options => ['-g'],
    require         => Package['npm'],
    notify          => Exec['bower dependencies'],
  }

  file { '/usr/bin/node':
    ensure  => 'link',
    target  => '/usr/bin/nodejs',
    require => Package['bower'],
  }

  exec { 'bower dependencies':
    command     => 'bower install --allow-root',
    cwd         => $regcert_dir,
    refreshonly => true,
    require     => [
      Package['bower'],
      Vcsrepo[$regcert_dir],
      file['/usr/bin/node'],
    ],
  }


# Python ######################################################################

  if !defined(Class['python']) {
    class { 'python':
      version    => 'system',
      dev        => true,
      virtualenv => true,
      pip        => true,
    }
  }

  file { ['/srv/.virtualenvs',]:
    ensure  => 'directory',
    require => Vcsrepo[$regcert_dir],
  }

  python::virtualenv { $regcert_venv_dir:
    require => [
      File['/srv/.virtualenvs'],
      Vcsrepo[$regcert_dir],
    ],
  }

  python::requirements { "${regcert_dir}/requirements/prod-requirements.txt":
    virtualenv => $regcert_venv_dir,
    forceupdate => true,
    require     => [
      Python::Virtualenv[$regcert_venv_dir],
      Vcsrepo[$regcert_dir],
      Package[$package_deps],
    ],
  }


# Supervisor ##################################################################

  supervisor::app { 'regcert':
    command   => "${regcert_dir}/bin/run_regcert",
    directory => $regcert_dir,
    require   => [
      Vcsrepo[$regcert_dir],
      Exec['collectstatic'],
      Exec['compilemessages'],
      Exec['migrate'],
      Python::Requirements["${regcert_dir}/requirements/prod-requirements.txt"],
    ],
  }


# NGINX #######################################################################

  file { [ '/var/log/regcert',
           '/var/run/regcert']:
    ensure => 'directory',
    owner => 'regcert',
    group => 'regcert',
    require => Vcsrepo[$regcert_dir],
  }

  class { 'nginx': }

  nginx::resource::upstream { 'regcert_app_server':
    members               => ['127.0.0.1:8001'],
    upstream_fail_timeout => 0,
  }

  nginx::resource::vhost { $regcert_vhost:
    client_max_body_size => '4G',
    access_log           => '/var/log/regcert/regcert-access.log',
    error_log            => '/var/log/regcert/regcert-error.log',
    use_default_location => false,
    require              => Vcsrepo[$regcert_dir],
    proxy_set_header     => ['X-Forwarded-For $proxy_add_x_forwarded_for',
                             'Host $http_host'],
  }

  nginx::resource::location { '/':
    vhost                      => $regcert_vhost,
    location_custom_cfg        => { proxy_redirect => 'off' },
    location_custom_cfg_append => [ 'if (!-f $request_filename) {',
                                    '   proxy_pass http://regcert_app_server;',
                                    '   break;',
                                    ' }'],
  }

  nginx::resource::location { '/static/':
    vhost          => $regcert_vhost,
    location_alias => '/srv/regcert/src/static_root/',
  }


  # Deploy ####################################################################

  exec { 'collectstatic':
    command     => "${regcert_venv_dir}/bin/python manage.py collectstatic --noinput",
    cwd         => "${regcert_dir}/src",
    refreshonly => true,
    require     => [
      Exec['bower dependencies'],
      Vcsrepo[$regcert_dir],
      Python::Requirements["${regcert_dir}/requirements/prod-requirements.txt"],
    ],
  }

  exec { 'compilemessages':
    command     => "${regcert_venv_dir}/bin/python manage.py compilemessages",
    cwd         => "${regcert_dir}/src",
    refreshonly => true,
    require     => [
      Vcsrepo[$regcert_dir],
      Python::Requirements["${regcert_dir}/requirements/prod-requirements.txt"],
    ],
  }

  exec { 'migrate':
    command     => "${regcert_venv_dir}/bin/python manage.py migrate --noinput",
    cwd         => "${regcert_dir}/src",
    refreshonly => true,
    require     => [
      Vcsrepo[$regcert_dir],
      Python::Requirements["${regcert_dir}/requirements/prod-requirements.txt"],
    ],
  }

  service { 'supervisor':
    ensure => 'running',
    refreshonly => true,
    restart => 'supervisorctl restart regcert',
    require => Supervisor::App['regcert']
  }
}
