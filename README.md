threaded-mp3-transcoder
=======================

transcodes multi threaded from mp3s to mp3s, with optimized bitrate

this wraps 'lame --vbr-new -b 32 -B 320 -m j source-file destination-file'


_installation_

sudo perl -MCPAN -e '\
        install Data::Dumper;\
        install File::Basename;\
        install File::Copy;\
        install File::Find;\
        install File::Path;\
        install File::Temp;\
        install Proc::NiceSleep;\
        install Thread::Queue;\
        install Time::HiRes;\
        install Unix::Process'
        
_usage_

perl threaded_mp3_encoder.pl <source-directory> <target-directory>

![screenshot](https://github.com/lkwg82/threaded-mp3-transcoder/blob/master/screenshot.png?raw=true "Optional title")
