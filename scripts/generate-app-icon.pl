#!/usr/bin/env perl

use strict;
use warnings;
use Compress::Zlib qw(compress crc32);

my $output = shift // die "usage: $0 OUTPUT.png\n";
my $size = 1024;

sub rounded_rect {
    my ($x, $y, $left, $top, $right, $bottom, $radius) = @_;
    return 0 if $x < $left || $x >= $right || $y < $top || $y >= $bottom;

    my $center_x = $x < $left + $radius
        ? $left + $radius
        : $x >= $right - $radius ? $right - $radius - 1 : $x;
    my $center_y = $y < $top + $radius
        ? $top + $radius
        : $y >= $bottom - $radius ? $bottom - $radius - 1 : $y;
    my $dx = $x - $center_x;
    my $dy = $y - $center_y;
    return $dx * $dx + $dy * $dy <= $radius * $radius;
}

sub circle {
    my ($x, $y, $center_x, $center_y, $radius) = @_;
    my $dx = $x - $center_x;
    my $dy = $y - $center_y;
    return $dx * $dx + $dy * $dy <= $radius * $radius;
}

my $pixels = '';
for my $y (0 .. $size - 1) {
    $pixels .= "\0";
    for my $x (0 .. $size - 1) {
        my @color = (22, 28, 30);

        if (rounded_rect($x, $y, 420, 680, 604, 818, 30)
            || rounded_rect($x, $y, 320, 785, 704, 850, 32)) {
            @color = (220, 228, 224);
        }

        if (rounded_rect($x, $y, 120, 170, 904, 735, 96)) {
            @color = (241, 245, 242);
        }

        if (rounded_rect($x, $y, 175, 225, 849, 650, 58)) {
            @color = (30, 42, 44);
        }

        if (rounded_rect($x, $y, 448, 288, 576, 588, 52)
            || rounded_rect($x, $y, 362, 374, 662, 502, 52)) {
            @color = (62, 204, 127);
        }

        if (circle($x, $y, 512, 438, 58)) {
            @color = (241, 245, 242);
        }

        if (circle($x, $y, 512, 438, 26)) {
            @color = (30, 42, 44);
        }

        if (circle($x, $y, 798, 692, 13)) {
            @color = (48, 177, 204);
        }

        $pixels .= pack('C3', @color);
    }
}

sub png_chunk {
    my ($type, $data) = @_;
    return pack('N', length($data))
        . $type
        . $data
        . pack('N', crc32($type . $data));
}

my $png = "\x89PNG\r\n\x1a\n";
$png .= png_chunk('IHDR', pack('NNCCCCC', $size, $size, 8, 2, 0, 0, 0));
$png .= png_chunk('IDAT', compress($pixels, 9));
$png .= png_chunk('IEND', '');

open my $file, '>:raw', $output or die "cannot open $output: $!\n";
print {$file} $png or die "cannot write $output: $!\n";
close $file or die "cannot close $output: $!\n";
