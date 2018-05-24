公司k8s尝试相关 
===========================

|Author|James|
|---|---
|E-mail|dengwei@thinker.vc

公司原有运维存在的问题
-----
非互联网的传统IT公司，并不存在高并发访问量大的，主要是业务形态多、项目杂引起的一系列问题：

1. 我们主要使用阿里云服务，有时候为了省钱也会购买华为云或者腾讯云的ECS，总体上是想降成本，但这引发服务器无法统一管理的问题增加了运维成本；
2. 过多的产品线导致需要搭建非常多的环境，比如测试环境、开发环境、演示环境，日积月累后运维人员很难记得那些ECS上部署了什么服务，这些ECS上还有多少容量（cpu、内存）;
3. 还是环境过多引起的问题，许多环境并不是一直使用我们会停止它节省资源，但是当某个演示环境要使用的时候重新启动或者重新部署都很麻烦；
4. 由于有很多演示环境，平时使用频率很低，我们并没有做服务的状态监控，经常发生服务挂了很久都没有人知道;
5. 在日常开发中，由于缺少滚动更新策略，移动端经常抱怨后台服务又挂了，其实是后台人员在重新部署;


解决问题
-----
尝试使用k8s解决上述问题


目录说明

[aliyun_install](./aliyun_install)
阿里云上安装 k8s 1.10 版本

