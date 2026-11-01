# Echo baseline retake on GitHub's Linux runners, 2026-11-01

Two runs of the `comparison` job failed `bench/baseline/echo.txt` on 2026-11-01 with no change to the
echo servers or the client. One ran on an AMD EPYC 9V74, and one on an arm64 runner. So I retook the
sections from every Linux comparison job on `1dc6c8d` and `3c3764d`, whose echo servers and client
are the same. That is 26 jobs from seven runs of `.github/workflows/ci.yml`, started by hand:

- runs 41259129302, 41259130907, 41259132393, 41259133814 and 41259135577 on `1dc6c8d`, one job
  of each Linux processor kind a run;
- runs 41268088924 and 41268090610 on `3c3764d`, with `comparison_runs` set to `[1, 2, 3, 4]`.

Each job is three runs a row, on io_uring, on one core. A table column is one job, named by its job
id. A cell is the job's ratio, the candidate's echoes per second in thousandths of rotor's. A cell
reads "disagreed" when the row's runs, or rotor's runs of that row, disagreed in that job.

## How the sections changed

- The arm64 section, `CPU implementer 0x41 part 0xd49`, had 13 jobs. Each row is now the highest of
  them, as `89a4430` retook it from eight. Some rows fell and some rose.
- Every other section had 1 to 6 jobs. Each row became the higher of its old ratio and the highest
  of its jobs, as on 2026-09-25.
- No job ran on an Intel Xeon Platinum 8370C, so that section did not change.

## What the jobs show

On the AMD EPYC 9V74 and 9V45, almost every row rose against the section, `rotor (accumulate)`
among them. A ratio divides a candidate's rate by rotor's. So on those two processors the default
shape of `rotor_echo` is slower against the others than when the sections were taken, from
2026-09-24 to 2026-09-27. These jobs do not show the cause. They also do not show that rotor itself
got slower: only paired runs of the old and the new tree on one runner can show that.

On the other processors about half the rows rose, or fewer. The highest of several jobs rises with
the number of jobs, so those rows show no clear change.

| processor | jobs | rows above the section | largest rise | the row of the largest rise |
|---|---:|---|---:|---|
| AMD EPYC 9V74 | 3 | 31 of 32 | 69 | 16 connections, 65536 bytes, libuv |
| AMD EPYC 9V45 | 2 | 31 of 32 | 37 | 16 connections, 65536 bytes, std.Io.Threaded |
| AMD EPYC 7763 | 6 | 17 of 32 | 34 | 64 connections, 65536 bytes, std.Io.Threaded |
| arm64 0xd49 | 13 | 15 of 32 | 56 | 64 connections, 65536 bytes, libxev |
| Intel Xeon 6973P-C | 1 | 8 of 31 | 38 | 16 connections, 8192 bytes, rotor (accumulate) |
| Intel Xeon Platinum 8573C | 1 | 6 of 31 | 9 | 64 connections, 65536 bytes, rotor (accumulate) |

The rotor rows are left out of the count, because each is 1000 by definition.

## AMD EPYC 7763 64-Core Processor

| connections | payload | candidate | before | 124735005070 | 124735004891 | 124708559332 | 124708545239 | 124735005094 | 124735010835 | after |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 4096 | libuv | 879 | 874 | 876 | 880 | 882 | 882 | 886 | 886 |
| 16 | 4096 | libxev | 902 | 908 | 901 | 905 | 904 | 911 | 911 | 911 |
| 16 | 4096 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 4096 | rotor (accumulate) | 954 | 962 | 946 | 947 | 961 | 960 | 966 | 966 |
| 16 | 4096 | std.Io.Threaded | 517 | 510 | 511 | 519 | 517 | 522 | 514 | 522 |
| 16 | 8192 | libuv | 893 | 875 | 885 | 897 | 883 | 881 | 877 | 897 |
| 16 | 8192 | libxev | 913 | 888 | 907 | 910 | 902 | 897 | 889 | 913 |
| 16 | 8192 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 8192 | rotor (accumulate) | 952 | 959 | 963 | 962 | 967 | 953 | 953 | 967 |
| 16 | 8192 | std.Io.Threaded | 527 | 510 | 518 | 525 | 514 | 514 | 507 | 527 |
| 16 | 16384 | libuv | 951 | 882 | 883 | 889 | 889 | 899 | 890 | 951 |
| 16 | 16384 | libxev | 957 | 903 | 891 | 901 | 902 | 908 | 898 | 957 |
| 16 | 16384 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 16384 | rotor (accumulate) | 982 | 960 | 938 | 937 | 941 | 952 | 949 | 982 |
| 16 | 16384 | std.Io.Threaded | 562 | 512 | 512 | 531 | 519 | 523 | 519 | 562 |
| 16 | 65536 | libuv | 979 | 969 | 967 | 966 | 969 | 959 | 971 | 979 |
| 16 | 65536 | libxev | 975 | 980 | 974 | 976 | 943 | 983 | 969 | 983 |
| 16 | 65536 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 65536 | rotor (accumulate) | 1008 | 1003 | 983 | 999 | 984 | 997 | 984 | 1008 |
| 16 | 65536 | std.Io.Threaded | 656 | 677 | 677 | 680 | 671 | 677 | 670 | 680 |
| 64 | 4096 | libuv | 876 | 865 | 866 | 885 | 865 | 867 | 860 | 885 |
| 64 | 4096 | libxev | 936 | 933 | 934 | 956 | 932 | 931 | 923 | 956 |
| 64 | 4096 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 4096 | rotor (accumulate) | 952 | 948 | 939 | 973 | 942 | 945 | 939 | 973 |
| 64 | 4096 | std.Io.Threaded | 549 | 505 | 511 | 514 | 512 | 513 | 503 | 549 |
| 64 | 8192 | libuv | 907 | 882 | 893 | 903 | 878 | 879 | 887 | 907 |
| 64 | 8192 | libxev | 942 | 951 | 952 | 954 | 931 | 933 | 950 | 954 |
| 64 | 8192 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 8192 | rotor (accumulate) | 952 | 964 | 964 | 980 | 939 | 941 | 959 | 980 |
| 64 | 8192 | std.Io.Threaded | 564 | 513 | 524 | 529 | 513 | 516 | 518 | 564 |
| 64 | 16384 | libuv | 934 | 890 | 917 | 909 | 897 | 900 | 904 | 934 |
| 64 | 16384 | libxev | 961 | 968 | 989 | 966 | 942 | 950 | 961 | 989 |
| 64 | 16384 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 16384 | rotor (accumulate) | 982 | 982 | 993 | 994 | 954 | 957 | 973 | 994 |
| 64 | 16384 | std.Io.Threaded | 584 | 522 | 530 | 530 | 517 | 522 | 525 | 584 |
| 64 | 65536 | libuv | 1000 | 977 | 995 | 995 | 1000 | 978 | 1004 | 1004 |
| 64 | 65536 | libxev | 1008 | 992 | 982 | 972 | 986 | 995 | 995 | 1008 |
| 64 | 65536 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 65536 | rotor (accumulate) | 1039 | 1008 | 1009 | 996 | 1020 | 1010 | 1005 | 1039 |
| 64 | 65536 | std.Io.Threaded | 657 | 665 | 681 | 670 | 672 | 674 | 691 | 691 |

## AMD EPYC 9V45 96-Core Processor

| connections | payload | candidate | before | 124735010999 | 124735010935 | after |
|---:|---:|---|---:|---:|---:|---:|
| 16 | 4096 | libuv | 870 | 876 | 881 | 881 |
| 16 | 4096 | libxev | 925 | 936 | 939 | 939 |
| 16 | 4096 | rotor | 1000 | 1000 | 1000 | 1000 |
| 16 | 4096 | rotor (accumulate) | 943 | 968 | 955 | 968 |
| 16 | 4096 | std.Io.Threaded | 653 | 665 | 667 | 667 |
| 16 | 8192 | libuv | 885 | 880 | 880 | 885 |
| 16 | 8192 | libxev | 928 | 941 | 938 | 941 |
| 16 | 8192 | rotor | 1000 | 1000 | 1000 | 1000 |
| 16 | 8192 | rotor (accumulate) | 949 | 965 | 951 | 965 |
| 16 | 8192 | std.Io.Threaded | 654 | 662 | 659 | 662 |
| 16 | 16384 | libuv | 878 | 854 | 888 | 888 |
| 16 | 16384 | libxev | 921 | 942 | 949 | 949 |
| 16 | 16384 | rotor | 1000 | 1000 | 1000 | 1000 |
| 16 | 16384 | rotor (accumulate) | 931 | 952 | 961 | 961 |
| 16 | 16384 | std.Io.Threaded | 642 | 655 | 656 | 656 |
| 16 | 65536 | libuv | 975 | 971 | 1009 | 1009 |
| 16 | 65536 | libxev | 981 | 946 | 996 | 996 |
| 16 | 65536 | rotor | 1000 | 1000 | 1000 | 1000 |
| 16 | 65536 | rotor (accumulate) | 1000 | 971 | 1006 | 1006 |
| 16 | 65536 | std.Io.Threaded | 801 | 801 | 838 | 838 |
| 64 | 4096 | libuv | 874 | 887 | 880 | 887 |
| 64 | 4096 | libxev | 946 | 973 | 945 | 973 |
| 64 | 4096 | rotor | 1000 | 1000 | 1000 | 1000 |
| 64 | 4096 | rotor (accumulate) | 947 | 971 | 966 | 971 |
| 64 | 4096 | std.Io.Threaded | 657 | 669 | 677 | 677 |
| 64 | 8192 | libuv | 867 | 891 | 875 | 891 |
| 64 | 8192 | libxev | 941 | 959 | 960 | 960 |
| 64 | 8192 | rotor | 1000 | 1000 | 1000 | 1000 |
| 64 | 8192 | rotor (accumulate) | 948 | 951 | 951 | 951 |
| 64 | 8192 | std.Io.Threaded | 649 | 669 | 661 | 669 |
| 64 | 16384 | libuv | 869 | 897 | 900 | 900 |
| 64 | 16384 | libxev | 923 | 958 | 937 | 958 |
| 64 | 16384 | rotor | 1000 | 1000 | 1000 | 1000 |
| 64 | 16384 | rotor (accumulate) | 943 | 957 | 952 | 957 |
| 64 | 16384 | std.Io.Threaded | 649 | 661 | 656 | 661 |
| 64 | 65536 | libuv | 986 | 991 | 983 | 991 |
| 64 | 65536 | libxev | 986 | 990 | 987 | 990 |
| 64 | 65536 | rotor | 1000 | 1000 | 1000 | 1000 |
| 64 | 65536 | rotor (accumulate) | 994 | 997 | 987 | 997 |
| 64 | 65536 | std.Io.Threaded | 794 | 809 | 802 | 809 |

## AMD EPYC 9V74 80-Core Processor

| connections | payload | candidate | before | 124708549584 | 124708541018 | 124735004973 | after |
|---:|---:|---|---:|---:|---:|---:|---:|
| 16 | 4096 | libuv | 798 | 801 | 810 | 845 | 845 |
| 16 | 4096 | libxev | 900 | 901 | 904 | 915 | 915 |
| 16 | 4096 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 4096 | rotor (accumulate) | 948 | 954 | 948 | 972 | 972 |
| 16 | 4096 | std.Io.Threaded | 577 | 567 | 590 | 590 | 590 |
| 16 | 8192 | libuv | 803 | 821 | 805 | 811 | 821 |
| 16 | 8192 | libxev | 908 | 926 | 906 | 908 | 926 |
| 16 | 8192 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 8192 | rotor (accumulate) | 958 | 965 | 964 | 967 | 967 |
| 16 | 8192 | std.Io.Threaded | 577 | 582 | 590 | 588 | 590 |
| 16 | 16384 | libuv | 823 | 842 | 812 | 840 | 842 |
| 16 | 16384 | libxev | 931 | 957 | 919 | 938 | 957 |
| 16 | 16384 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 16384 | rotor (accumulate) | 976 | 983 | 965 | 991 | 991 |
| 16 | 16384 | std.Io.Threaded | 589 | 604 | 596 | 591 | 604 |
| 16 | 65536 | libuv | 955 | 989 | 1024 | 977 | 1024 |
| 16 | 65536 | libxev | 1014 | 1019 | 1063 | 983 | 1063 |
| 16 | 65536 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 65536 | rotor (accumulate) | 1027 | 1034 | 1088 | 1030 | 1088 |
| 16 | 65536 | std.Io.Threaded | 714 | 730 | 770 | 735 | 770 |
| 64 | 4096 | libuv | 808 | 809 | 816 | 793 | 816 |
| 64 | 4096 | libxev | 944 | 956 | 943 | 936 | 956 |
| 64 | 4096 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 4096 | rotor (accumulate) | 954 | 961 | 952 | 948 | 961 |
| 64 | 4096 | std.Io.Threaded | 580 | 592 | 593 | 578 | 593 |
| 64 | 8192 | libuv | 834 | 845 | 822 | 819 | 845 |
| 64 | 8192 | libxev | 960 | 976 | 960 | 942 | 976 |
| 64 | 8192 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 8192 | rotor (accumulate) | 971 | 976 | 967 | 953 | 976 |
| 64 | 8192 | std.Io.Threaded | 599 | 604 | 607 | 593 | 607 |
| 64 | 16384 | libuv | 832 | 817 | 829 | 839 | 839 |
| 64 | 16384 | libxev | 951 | 948 | 952 | 950 | 952 |
| 64 | 16384 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 16384 | rotor (accumulate) | 959 | 957 | 958 | 954 | 959 |
| 64 | 16384 | std.Io.Threaded | 597 | 581 | 612 | 588 | 612 |
| 64 | 65536 | libuv | 925 | 966 | 945 | 968 | 968 |
| 64 | 65536 | libxev | 1043 | 1073 | 1091 | 1050 | 1091 |
| 64 | 65536 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 65536 | rotor (accumulate) | 1053 | 1076 | 1101 | 1021 | 1101 |
| 64 | 65536 | std.Io.Threaded | 687 | 709 | 747 | 695 | 747 |

## CPU implementer 0x41 part 0xd49

| connections | payload | candidate | before | 124708559340 | 124735005056 | 124735011035 | 124708545243 | 124735005006 | 124708549559 | 124735010608 | 124708555081 | 124735010984 | 124735005096 | 124735004978 | 124735010953 | 124708541020 | after |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 16 | 4096 | libuv | 863 | 775 | 785 | 786 | 792 | 793 | 799 | 799 | 803 | 804 | 807 | 812 | 824 | 833 | 833 |
| 16 | 4096 | libxev | 918 | 861 | 883 | 870 | 898 | 880 | 911 | 871 | 901 | 907 | 910 | 901 | 905 | 892 | 911 |
| 16 | 4096 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 4096 | rotor (accumulate) | 996 | 977 | 951 | 984 | 959 | 972 | 991 | 971 | 971 | 977 | 966 | 985 | 993 | 974 | 993 |
| 16 | 4096 | std.Io.Threaded | 641 | 616 | 633 | 618 | 646 | 638 | 642 | 614 | 631 | 629 | 637 | 634 | 643 | 647 | 647 |
| 16 | 8192 | libuv | 846 | 797 | 811 | 781 | 798 | 816 | 812 | 789 | 804 | 806 | 806 | 789 | 812 | 797 | 816 |
| 16 | 8192 | libxev | 913 | 877 | 918 | 865 | 903 | 919 | 925 | 872 | 912 | 886 | 915 | 892 | 908 | 880 | 925 |
| 16 | 8192 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 16 | 8192 | rotor (accumulate) | 977 | 968 | 944 | 954 | 959 | 961 | 970 | 956 | 979 | 962 | 956 | 956 | 980 | 959 | 980 |
| 16 | 8192 | std.Io.Threaded | 653 | 657 | 650 | 627 | 642 | 650 | 666 | 625 | 650 | 639 | 651 | 625 | 661 | 636 | 666 |
| 16 | 16384 | libuv | 957 | 883 | 903 | disagreed | 875 | 916 | 864 | 859 | 856 | 881 | 899 | 891 | 882 | disagreed | 916 |
| 16 | 16384 | libxev | 1030 | 937 | 966 | disagreed | 946 | 972 | 961 | 919 | 890 | 951 | 1016 | 960 | 906 | disagreed | 1016 |
| 16 | 16384 | rotor | 1000 | 1000 | 1000 | disagreed | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | disagreed | 1000 |
| 16 | 16384 | rotor (accumulate) | 1045 | 1015 | 1032 | disagreed | 986 | 996 | 989 | 986 | 971 | 974 | 1036 | 1010 | 972 | disagreed | 1036 |
| 16 | 16384 | std.Io.Threaded | 755 | 705 | 736 | disagreed | 702 | 716 | 720 | 686 | 687 | 710 | 752 | 699 | 694 | disagreed | 752 |
| 16 | 65536 | libuv | 1082 | 1006 | 986 | 1001 | 1011 | 1034 | 1056 | 1061 | 1020 | 1051 | 1032 | 1032 | 1021 | disagreed | 1061 |
| 16 | 65536 | libxev | 1074 | 947 | 959 | 977 | 964 | 1030 | 1015 | 1063 | 963 | 1044 | 965 | 995 | 982 | disagreed | 1063 |
| 16 | 65536 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | disagreed | 1000 |
| 16 | 65536 | rotor (accumulate) | 1034 | 996 | 984 | 990 | 999 | 1042 | 1021 | 1032 | disagreed | 1045 | 1002 | 1010 | 1007 | disagreed | 1045 |
| 16 | 65536 | std.Io.Threaded | 1036 | 918 | 901 | 915 | 921 | 963 | 953 | 990 | 959 | 957 | 930 | 937 | 934 | disagreed | 990 |
| 64 | 4096 | libuv | 848 | 854 | 828 | 822 | 853 | 805 | 833 | 836 | 835 | 818 | 829 | 817 | 851 | 833 | 854 |
| 64 | 4096 | libxev | 960 | 931 | 878 | 903 | 887 | 866 | 874 | 865 | 886 | 863 | 905 | 921 | 925 | 908 | 931 |
| 64 | 4096 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 4096 | rotor (accumulate) | 965 | 964 | 916 | 910 | 960 | 906 | 945 | 949 | 958 | 934 | 943 | 900 | 969 | 943 | 969 |
| 64 | 4096 | std.Io.Threaded | 618 | 639 | 620 | 633 | 627 | 605 | 614 | 616 | 587 | 614 | 641 | 618 | 638 | 615 | 641 |
| 64 | 8192 | libuv | 910 | 858 | 886 | disagreed | 849 | 825 | 850 | disagreed | 948 | 880 | disagreed | 861 | 843 | 796 | 948 |
| 64 | 8192 | libxev | 986 | 879 | 953 | disagreed | 856 | 863 | 885 | disagreed | 956 | 875 | disagreed | 851 | 910 | 864 | 956 |
| 64 | 8192 | rotor | 1000 | 1000 | 1000 | disagreed | 1000 | 1000 | 1000 | disagreed | 1000 | 1000 | disagreed | 1000 | 1000 | 1000 | 1000 |
| 64 | 8192 | rotor (accumulate) | 993 | 891 | 981 | disagreed | 894 | 862 | 911 | disagreed | disagreed | 903 | disagreed | 881 | 896 | 893 | 981 |
| 64 | 8192 | std.Io.Threaded | 681 | 661 | 723 | disagreed | 651 | 648 | 671 | disagreed | 728 | 668 | disagreed | 658 | 684 | 657 | 728 |
| 64 | 16384 | libuv | 930 | 909 | disagreed | 909 | 895 | 897 | 896 | 918 | disagreed | 898 | 890 | 915 | 905 | 876 | 918 |
| 64 | 16384 | libxev | 977 | 934 | disagreed | 932 | 888 | 920 | 915 | 951 | disagreed | 922 | 935 | 950 | 900 | 899 | 951 |
| 64 | 16384 | rotor | 1000 | 1000 | disagreed | 1000 | 1000 | 1000 | 1000 | 1000 | disagreed | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 |
| 64 | 16384 | rotor (accumulate) | 995 | 932 | disagreed | 954 | 912 | 921 | 933 | 976 | disagreed | 920 | 927 | 967 | 933 | 920 | 976 |
| 64 | 16384 | std.Io.Threaded | 756 | 769 | disagreed | 753 | 746 | 738 | 748 | 760 | disagreed | 746 | 769 | 752 | 746 | 732 | 769 |
| 64 | 65536 | libuv | 1057 | 1008 | 1028 | 1005 | 1084 | 1022 | 1044 | disagreed | 1008 | 1031 | 1051 | 1026 | disagreed | disagreed | 1084 |
| 64 | 65536 | libxev | 1006 | 984 | 1001 | 981 | 1062 | 1003 | 983 | disagreed | 1002 | 977 | 1015 | 987 | disagreed | disagreed | 1062 |
| 64 | 65536 | rotor | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | 1000 | disagreed | 1000 | 1000 | 1000 | 1000 | disagreed | disagreed | 1000 |
| 64 | 65536 | rotor (accumulate) | 1001 | 985 | 1016 | 986 | 1055 | 1005 | 995 | disagreed | 1005 | 1002 | 1010 | 1016 | disagreed | disagreed | 1055 |
| 64 | 65536 | std.Io.Threaded | 1000 | 947 | 970 | 939 | 1006 | 954 | 961 | disagreed | 958 | 969 | 943 | 962 | disagreed | disagreed | 1006 |

## INTEL(R) XEON(R) PLATINUM 8573C

| connections | payload | candidate | before | 124708555056 | after |
|---:|---:|---|---:|---:|---:|
| 16 | 4096 | libuv | 836 | 820 | 836 |
| 16 | 4096 | rotor | 1000 | 1000 | 1000 |
| 16 | 4096 | rotor (accumulate) | 949 | 951 | 951 |
| 16 | 4096 | std.Io.Threaded | 600 | 566 | 600 |
| 16 | 8192 | libuv | 855 | 810 | 855 |
| 16 | 8192 | libxev | 915 | 860 | 915 |
| 16 | 8192 | rotor | 1000 | 1000 | 1000 |
| 16 | 8192 | rotor (accumulate) | 983 | 969 | 983 |
| 16 | 8192 | std.Io.Threaded | 589 | 554 | 589 |
| 16 | 16384 | libuv | 851 | 834 | 851 |
| 16 | 16384 | libxev | 916 | 881 | 916 |
| 16 | 16384 | rotor | 1000 | 1000 | 1000 |
| 16 | 16384 | rotor (accumulate) | 1000 | 1005 | 1005 |
| 16 | 16384 | std.Io.Threaded | 579 | 551 | 579 |
| 16 | 65536 | libuv | 1024 | 1025 | 1025 |
| 16 | 65536 | libxev | 1026 | 992 | 1026 |
| 16 | 65536 | rotor | 1000 | 1000 | 1000 |
| 16 | 65536 | rotor (accumulate) | 1048 | 1037 | 1048 |
| 16 | 65536 | std.Io.Threaded | 729 | 712 | 729 |
| 64 | 4096 | libuv | 856 | 826 | 856 |
| 64 | 4096 | libxev | 909 | 877 | 909 |
| 64 | 4096 | rotor | 1000 | 1000 | 1000 |
| 64 | 4096 | rotor (accumulate) | 1020 | 1004 | 1020 |
| 64 | 4096 | std.Io.Threaded | 594 | 524 | 594 |
| 64 | 8192 | libuv | 852 | 844 | 852 |
| 64 | 8192 | libxev | 933 | 908 | 933 |
| 64 | 8192 | rotor | 1000 | 1000 | 1000 |
| 64 | 8192 | rotor (accumulate) | 996 | 995 | 996 |
| 64 | 8192 | std.Io.Threaded | 569 | 526 | 569 |
| 64 | 16384 | libuv | 905 | 881 | 905 |
| 64 | 16384 | libxev | 961 | 952 | 961 |
| 64 | 16384 | rotor | 1000 | 1000 | 1000 |
| 64 | 16384 | rotor (accumulate) | 982 | 981 | 982 |
| 64 | 16384 | std.Io.Threaded | 542 | 496 | 542 |
| 64 | 65536 | libuv | 1063 | 1064 | 1064 |
| 64 | 65536 | libxev | 1012 | 1015 | 1015 |
| 64 | 65536 | rotor | 1000 | 1000 | 1000 |
| 64 | 65536 | rotor (accumulate) | 1003 | 1012 | 1012 |
| 64 | 65536 | std.Io.Threaded | 762 | 721 | 762 |

## Intel(R) Xeon(R) 6973P-C

| connections | payload | candidate | before | 124735010851 | after |
|---:|---:|---|---:|---:|---:|
| 16 | 4096 | libuv | 834 | 811 | 834 |
| 16 | 4096 | libxev | 751 | 729 | 751 |
| 16 | 4096 | rotor | 1000 | 1000 | 1000 |
| 16 | 4096 | rotor (accumulate) | 961 | 974 | 974 |
| 16 | 4096 | std.Io.Threaded | 563 | 526 | 563 |
| 16 | 8192 | libuv | 806 | 814 | 814 |
| 16 | 8192 | libxev | 755 | 765 | 765 |
| 16 | 8192 | rotor | 1000 | 1000 | 1000 |
| 16 | 8192 | rotor (accumulate) | 962 | 1000 | 1000 |
| 16 | 8192 | std.Io.Threaded | 541 | 523 | 541 |
| 16 | 16384 | libuv | 812 | 800 | 812 |
| 16 | 16384 | rotor | 1000 | 1000 | 1000 |
| 16 | 16384 | rotor (accumulate) | 995 | 986 | 995 |
| 16 | 16384 | std.Io.Threaded | 524 | 512 | 524 |
| 16 | 65536 | libuv | 1002 | 989 | 1002 |
| 16 | 65536 | libxev | 949 | 932 | 949 |
| 16 | 65536 | rotor | 1000 | 1000 | 1000 |
| 16 | 65536 | rotor (accumulate) | 1026 | 1010 | 1026 |
| 16 | 65536 | std.Io.Threaded | 644 | 629 | 644 |
| 64 | 4096 | libuv | 830 | 846 | 846 |
| 64 | 4096 | libxev | 789 | 770 | 789 |
| 64 | 4096 | rotor | 1000 | 1000 | 1000 |
| 64 | 4096 | rotor (accumulate) | 1008 | 991 | 1008 |
| 64 | 4096 | std.Io.Threaded | 517 | 483 | 517 |
| 64 | 8192 | libuv | 819 | 823 | 823 |
| 64 | 8192 | libxev | 828 | 806 | 828 |
| 64 | 8192 | rotor | 1000 | 1000 | 1000 |
| 64 | 8192 | rotor (accumulate) | 977 | 978 | 978 |
| 64 | 8192 | std.Io.Threaded | 492 | 462 | 492 |
| 64 | 16384 | libuv | 873 | 868 | 873 |
| 64 | 16384 | libxev | 958 | 882 | 958 |
| 64 | 16384 | rotor | 1000 | 1000 | 1000 |
| 64 | 16384 | rotor (accumulate) | 978 | 988 | 988 |
| 64 | 16384 | std.Io.Threaded | 474 | 460 | 474 |
| 64 | 65536 | libuv | 1092 | 1032 | 1092 |
| 64 | 65536 | libxev | 1047 | 1010 | 1047 |
| 64 | 65536 | rotor | 1000 | 1000 | 1000 |
| 64 | 65536 | rotor (accumulate) | 1045 | 1008 | 1045 |
| 64 | 65536 | std.Io.Threaded | 763 | 701 | 763 |
