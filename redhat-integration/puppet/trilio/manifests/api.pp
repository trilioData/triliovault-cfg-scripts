class trilio::api {


    Exec { environment => [ "TVAULT_PACKAGE=tvault-contego-api" ] }
    exec { 'Install pip':
        command => 'easy_install --no-deps http://192.168.1.26:8081/packages/pip-7.1.2.tar.gz',
        path    => ['/usr/bin/','/usr/sbin/', '/usr/local/bin/'],
        unless  => 'export PIP_INS=`pip --version || true`;  $PIP_INS != pip* '
    }
    exec { 'Installapipackage':
        command => 'pip install --no-deps http://192.168.1.26:8081/packages/tvault-contego-api-3.0.5.tar.gz',
        path    => ['/usr/bin/','/usr/sbin/', '/usr/local/bin/'],
    }    

#    package {'dummy':
#        ensure   => present,
#        provider => pip,
   #     install_options => [ {'-f' => ' http://192.168.1.26:8081/packages/' }, 
                                   #{'--trusted-host' => '192.168.1.26'} ],	
	 
#	source   => "http://192.168.1.26:8081/packages/",
#    }

}
