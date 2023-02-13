class trilio::wlmapi::config_dynamic {
    tag 'wlmapiconfigdynamic'
      exec{ "get keystone resources":
          command => '/etc/triliovault-wlm/get_keystone_resources.sh',
          provider => shell,
      }

}
