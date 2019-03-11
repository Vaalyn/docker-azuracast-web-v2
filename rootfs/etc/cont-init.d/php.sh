#!/bin/sh

# Copy the php.ini template to its destination.
dockerize -template "/etc/php7/05-azuracast.ini.tmpl:/etc/php7/conf.d/05-azuracast.ini" /bin/true